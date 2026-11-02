#!/usr/bin/env bash
# Donnerkeule USB4 RDMA on Fedora 44 (Strix Halo / Framework Desktop).
#
# Reproduces the setup that was validated interactively:
#   - patched Fedora kernel (source-aware XDomain handler, kernel-workflow patches)
#   - thunderbolt_ibverbs DKMS module
#   - patched rdma-core usb4_rdma provider
#   - persistent module options, tbv0 dummy netdev, udev/limits/blacklist tweaks
#
# Usage:
#   ./fedora-strixhalo-setup.sh build-kernel            # once, on ONE host (~1h)
#   ./fedora-strixhalo-setup.sh install --ip 172.30.77.1/30 [--rpm-dir DIR]
#   ./fedora-strixhalo-setup.sh install --ip 172.30.77.2/30 --rpm-dir DIR   # other host
#
# Kernel command line (amd_iommu=off amdgpu.gttsize=... ttm.pages_limit=...)
# is NOT handled here; set it manually.
#
# After a reboot of one host, reload the module on the other: unload on BOTH
# hosts first, then load on one, then the other. Never Ctrl-C a benchmark.

set -euo pipefail

FORK_URL=${FORK_URL:-https://github.com/DigitalzombieTLD/donnerkeule}
FORK_BRANCH=${FORK_BRANCH:-fedora-7.2.14-patch}
REPO=${DONNERKEULE_DIR:-$HOME/donnerkeule}
RPM_DIR_DEFAULT=$HOME/tbv-kernel-rpms
BUILDID=${BUILDID:-.tbv2}
RDMA_CORE_DIR=${RDMA_CORE_DIR:-$HOME/rdma-core}
RDMA_CORE_TAG=${RDMA_CORE_TAG:-}   # default: tag matching installed rdma-core
RDMA_USER=${RDMA_USER:-$USER}
NET_CONN=tbv0

MODULE_OPTIONS="profile=linux_perf tbnet=prefer_rdma lanes=2 bind_services=1 allocate_rings=1 start_rings=1 negotiate_native=1 enable_tunnels=1 register_verbs=1 roce_netdev=tbv0 native_domain_mask=3 native_write_striping=1 dmabuf_verbs=1 dmabuf_coalesce_copy=1 dmabuf_reuse_buffers=1 nhi_interrupt_throttle_ns=0 dmabuf_host_direct=1 dmabuf_poll_us=25 dmabuf_push_done=1 dmabuf_credits=1 dmabuf_poll_control=1"

# Application order matters. The match-properties patch is the copy rebased for 7.2.14.
KERNEL_PATCHES=(
	0002-thunderbolt-tunnel-add-dma-priority-weight-params.patch
	0004-thunderbolt-nhi-clear-pending-before-unmask.patch
	0005-thunderbolt-xdomain-log-unmatched-protocol-uuids.patch
	0007-thunderbolt-xdomain-pass-source-to-protocol-handlers.patch
	0008-thunderbolt-xdomain-pin-protocol-handler-owner.patch
	0009-thunderbolt-xdomain-match-properties-by-identity.patch
	0010-thunderbolt-xdomain-drain-protocol-callbacks-on-unr.patch
	0009-thunderbolt-xdomain-lane-bonding-module-param.patch
)
REBASED_PATCH=0009-thunderbolt-xdomain-match-properties-by-identity.patch

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_not_root() { [ "$(id -u)" -ne 0 ] || die "run as a normal user (sudo is used where needed)"; }

ensure_repo() {
	if [ ! -d "$REPO/.git" ]; then
		log "Cloning $FORK_URL ($FORK_BRANCH) to $REPO"
		git clone -b "$FORK_BRANCH" "$FORK_URL" "$REPO"
	fi
	[ -f "$REPO/dkms.conf" ] || die "$REPO does not look like the donnerkeule tree"
}

patch_file() {
	local p=$1 dir=$REPO/kernel-workflow/patches
	if [ "$p" = "$REBASED_PATCH" ]; then
		if [ -f "$dir/fedora-7.2.14/$p" ]; then echo "$dir/fedora-7.2.14/$p"; return; fi
		local dst=$HOME/.tbv-fetched-$p
		curl -fL -o "$dst" \
			"https://raw.githubusercontent.com/DigitalzombieTLD/donnerkeule/$FORK_BRANCH/kernel-workflow/patches/fedora-7.2.14/$p"
		echo "$dst"
		return
	fi
	[ -f "$dir/$p" ] || die "missing patch $dir/$p"
	echo "$dir/$p"
}

build_kernel() {
	need_not_root
	ensure_repo
	local rpm_dir=${RPM_DIR:-$RPM_DIR_DEFAULT}

	log "Installing kernel build dependencies"
	sudo dnf install -y rpmdevtools rpm-build fedpkg fedora-packager pesign grubby \
		ncurses-devel dnf-plugins-core tmux
	sudo dnf builddep -y kernel

	rpmdev-setuptree
	local nvr
	nvr=$(uname -r | sed -E 's/\.x86_64$//; s/\.tbv[0-9]*//')
	log "Downloading kernel SRPM for $nvr"
	( cd "$HOME/rpmbuild/SRPMS" && dnf download --source "kernel-$nvr" )
	rpm -ivh "$HOME"/rpmbuild/SRPMS/kernel-"$nvr".src.rpm

	local spec=$HOME/rpmbuild/SPECS/kernel.spec
	[ -f "$spec" ] || die "spec not found: $spec"
	cp -n "$spec" "$spec.orig"

	log "Copying patches"
	local p src
	for p in "${KERNEL_PATCHES[@]}"; do
		src=$(patch_file "$p")
		cp "$src" "$HOME/rpmbuild/SOURCES/$p"
	done

	log "Editing kernel.spec (idempotent)"
	if ! grep -q '^Patch9001:' "$spec"; then
		local decl="" i=1 marker='^%description'
		for p in "${KERNEL_PATCHES[@]}"; do
			decl+="Patch$((9000 + i)): $p"$'\n'
			i=$((i + 1))
		done
		grep -q '^# END OF PATCH DEFINITIONS' "$spec" && marker='^# END OF PATCH DEFINITIONS'
		awk -v d="$decl" -v m="$marker" '$0 ~ m && !done { printf "%s", d; done=1 } { print }' \
			"$spec" > "$spec.new"
		mv "$spec.new" "$spec"
	fi
	if ! grep -q '^ApplyPatch 0002-thunderbolt' "$spec"; then
		local apply=""
		for p in "${KERNEL_PATCHES[@]}"; do apply+="ApplyPatch $p"$'\n'; done
		awk -v a="$apply" '{ print } /^ApplyOptionalPatch linux-kernel-test.patch/ && !done { printf "%s", a; done=1 }' \
			"$spec" > "$spec.new"
		mv "$spec.new" "$spec"
		grep -q '^ApplyPatch 0002-thunderbolt' "$spec" || die "could not insert ApplyPatch lines"
	fi
	sed -i -E "s/^#? ?%?define buildid .*/%define buildid $BUILDID/" "$spec"
	grep -q "^%define buildid $BUILDID" "$spec" || die "buildid not set in spec"

	log "Dry-running patch application (rpmbuild -bp)"
	rpmbuild -bp --target x86_64 "$spec" > "$HOME/kernel-bp.log" 2>&1 \
		|| { tail -30 "$HOME/kernel-bp.log"; die "patches do not apply to this kernel version"; }
	rm -rf "$HOME"/rpmbuild/BUILD/kernel-*

	log "Building kernel (about an hour). Log: ~/kbuild.log"
	rpmbuild -bb --target x86_64 \
		--without debug --without debuginfo --without selftests --without doc \
		--without perf --without tools --without bpftool --without cross_headers \
		--without realtime --without arm64_64k "$spec" 2>&1 | tee "$HOME/kbuild.log"

	mkdir -p "$rpm_dir"
	cp "$HOME"/rpmbuild/RPMS/x86_64/kernel-{core,modules,modules-core,modules-extra,devel}-*"$BUILDID".fc*.x86_64.rpm "$rpm_dir"/
	log "Done. RPMs in $rpm_dir. Copy that directory to the other host, then run 'install' on both hosts."
}

build_rdma_provider() {
	log "Building the patched rdma-core usb4_rdma provider"
	local tag=$RDMA_CORE_TAG
	[ -n "$tag" ] || tag="v$(rpm -q --qf '%{VERSION}' rdma-core)"
	[ -d "$RDMA_CORE_DIR/.git" ] || git clone https://github.com/linux-rdma/rdma-core.git "$RDMA_CORE_DIR"
	(
		cd "$RDMA_CORE_DIR"
		git fetch --tags -q
		git checkout -q -f "$tag"
		git clean -fdxq
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			patch -p1 < "$REPO/packaging/rdma-core-patches/$p"
		done < "$REPO/packaging/rdma-core-patches/series"
		cmake -S . -B build-usb4 -DNO_PYVERBS=1 >/dev/null
		cmake --build build-usb4 -j"$(nproc)"
	)
	local so
	so=$(ls "$RDMA_CORE_DIR"/build-usb4/lib/libusb4_rdma-rdmav*.so | head -1)
	[ -f "$so" ] || die "provider library not built"
	# Only the provider is installed; the distro's other rdma-core libraries stay as they are.
	sudo install -m 0755 "$so" /usr/lib64/libibverbs/
	sudo install -d /etc/libibverbs.d
	sudo install -m 0644 "$RDMA_CORE_DIR/providers/usb4_rdma/usb4_rdma.driver" /etc/libibverbs.d/
}

install_host() {
	need_not_root
	local ip="" rpm_dir=$RPM_DIR_DEFAULT
	while [ $# -gt 0 ]; do
		case $1 in
			--ip) ip=$2; shift 2 ;;
			--rpm-dir) rpm_dir=$2; shift 2 ;;
			*) die "unknown option: $1" ;;
		esac
	done
	[ -n "$ip" ] || die "--ip is required, e.g. 172.30.77.1/30 on one host and 172.30.77.2/30 on the other"
	ls "$rpm_dir"/kernel-core-*.rpm >/dev/null 2>&1 || die "no kernel RPMs in $rpm_dir (run build-kernel, then copy them here)"

	log "Installing packages"
	sudo dnf install -y dkms gcc make git cmake pahole elfutils-libelf-devel \
		rdma-core rdma-core-devel libibverbs-utils perftest pciutils ethtool \
		libnl3-devel systemd-devel python3-docutils pkgconf-pkg-config patch

	log "Installing patched kernel RPMs"
	sudo dnf install -y --disableexcludes=main "$rpm_dir"/kernel-*.rpm
	local kver
	kver=$(ls "$rpm_dir"/kernel-core-*.rpm | head -1 | sed -E 's/.*kernel-core-//; s/\.rpm$//')
	[ -d "/lib/modules/$kver" ] || die "kernel $kver not installed"
	log "Patched kernel: $kver"

	ensure_repo

	log "Building and installing the DKMS module for $kver"
	local pkg ver
	pkg=$(awk -F'"' '/^PACKAGE_NAME=/ {print $2; exit}' "$REPO/dkms.conf")
	ver=$(awk -F'"' '/^PACKAGE_VERSION=/ {print $2; exit}' "$REPO/dkms.conf")
	( cd "$REPO" && { dkms status 2>/dev/null | grep -q "^$pkg/$ver" || sudo make dkms-add; } )
	sudo dkms build "$pkg/$ver" -k "$kver"
	sudo dkms install "$pkg/$ver" -k "$kver" --force

	build_rdma_provider

	log "Module options, autoload and thunderbolt_net blacklist"
	echo "options thunderbolt_ibverbs $MODULE_OPTIONS" | sudo tee /etc/modprobe.d/thunderbolt_ibverbs.conf >/dev/null
	echo thunderbolt_ibverbs | sudo tee /etc/modules-load.d/thunderbolt_ibverbs.conf >/dev/null
	printf 'blacklist thunderbolt_net\ninstall thunderbolt_net /bin/false\n' \
		| sudo tee /etc/modprobe.d/blacklist-tbnet.conf >/dev/null

	log "Stopping udev from renaming usb4_rdma devices"
	sudo ln -sf /dev/null /etc/udev/rules.d/60-rdma-persistent-naming.rules
	sudo udevadm control --reload || true

	log "memlock limits for $RDMA_USER"
	printf '%s soft memlock unlimited\n%s hard memlock unlimited\n' "$RDMA_USER" "$RDMA_USER" \
		| sudo tee /etc/security/limits.d/99-rdma.conf >/dev/null

	log "tbv0 dummy interface ($ip) via NetworkManager"
	if nmcli -t -f NAME con show | grep -qx "$NET_CONN"; then
		sudo nmcli con mod "$NET_CONN" connection.autoconnect yes ipv4.method manual ipv4.addresses "$ip"
	else
		sudo nmcli con add type dummy ifname "$NET_CONN" con-name "$NET_CONN" \
			ipv4.method manual ipv4.addresses "$ip" connection.autoconnect yes
	fi

	log "Pinning the patched kernel"
	sudo grubby --set-default "/boot/vmlinuz-$kver"
	grep -q '^excludepkgs=kernel' /etc/dnf/dnf.conf 2>/dev/null \
		|| sudo sed -i '/^\[main\]/a excludepkgs=kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kernel-devel' /etc/dnf/dnf.conf

	cat <<EOF

Install complete on $(hostname).
Next: set the kernel command line manually, then reboot BOTH hosts at about the same time.
Verify after ~30 s (no manual module loading needed):
  uname -r                       # $kver
  ibv_devices                    # 4 devices with both cables
  ibv_devinfo -d usb4_rdma0 -v | grep -A1 'GID\['
  sudo grep -E '^peer|quarantined' /sys/kernel/debug/thunderbolt_ibverbs/peers | cut -c1-100
Benchmark (server first, then the client with the server's LAN hostname):
  ib_write_bw -d usb4_rdma0 -x 1 -F -s 16777216 -n 200 --report_gbits [server-host]
EOF
}

case "${1:-}" in
	build-kernel) shift; build_kernel "$@" ;;
	install) shift; install_host "$@" ;;
	*) sed -n '2,18p' "$0"; exit 1 ;;
esac
