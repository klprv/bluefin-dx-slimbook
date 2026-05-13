# Custom Bluefin DX image with Slimbook laptop support

ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin-dx

FROM ${BASE_IMAGE}:stable

# Install kernel-devel, Slimbook packages, and build akmod kernel modules.
#
# Why this is one big RUN:
# - Bluefin ships a stub kernel-devel (RPM registered, no files). We must
#   remove it and install the real package so akmodsbuild finds headers.
# - Slimbook akmod post-install scriptlets fail when run as root, so we
#   install with --setopt=tsflags=noscripts and drive akmodsbuild ourselves.
# - akmodsbuild refuses to run as root, so we drop to the akmods user.
# - In buildx, /tmp may not be world-writable for the akmods user, so we
#   chmod 1777 /tmp before dropping privileges.
# - kernel-devel is removed at the end to save space (modules already built).
RUN <<-EOF
	set -eux

	KVER=$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')
	echo "Building for kernel: ${KVER}"

	# Install REAL kernel-devel (replacing the stub entry in the RPM DB).
	# Active Fedora repos only carry the current kernel-devel; fall back to
	# Koji, which archives every build permanently.
	rpm -e --nodeps kernel-devel-${KVER} 2>/dev/null || true
	if ! dnf install -y kernel-devel-${KVER}; then
		KVER_VER="${KVER%%-*}"
		KVER_REST="${KVER#*-}"
		KVER_ARCH="${KVER_REST##*.}"
		KVER_REL="${KVER_REST%.*}"
		dnf install -y "https://kojipkgs.fedoraproject.org/packages/kernel/${KVER_VER}/${KVER_REL}/${KVER_ARCH}/kernel-devel-${KVER}.rpm"
	fi
	ls -la /usr/src/kernels/

	# Add Slimbook repository; fall back to the previous Fedora release if the
	# current one is not yet available in the Slimbook OBS repo.
	FEDORA_VER=$(rpm -E %fedora)
	dnf config-manager addrepo --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_${FEDORA_VER}/home:Slimbook.repo" \
		|| dnf config-manager addrepo --from-repofile="https://download.opensuse.org/repositories/home:/Slimbook/Fedora_$((FEDORA_VER - 1))/home:Slimbook.repo"

	# Install Slimbook packages, skipping akmod post-scripts (they fail as root)
	dnf install -y --setopt=tsflags=noscripts \
		slimbook-meta-common \
		slimbook-meta-evo \
		slimbook-meta-gnome \
		slimbook-service \
		slimbook-qc71-kmod \
		slimbook-qc71-kmod-common \
		slimbook-yt6801-kmod \
		slimbook-yt6801-kmod-common

	# Prepare a working directory and writable /tmp for the akmods user
	chmod 1777 /tmp
	mkdir -p /var/lib/akmods
	chown akmods:akmods /var/lib/akmods

	# Build each kernel module RPM as the akmods user
	ARCH=$(uname -m)
	for MODULE in slimbook-qc71-kmod slimbook-yt6801-kmod; do
		SRPM=$(ls /usr/src/akmods/${MODULE}-*.src.rpm)
		echo "Building ${MODULE} akmod RPM for kernel ${KVER}..."
		su -s /bin/bash akmods -c "cd /var/lib/akmods && HOME=/var/lib/akmods akmodsbuild --target ${ARCH} --kernels ${KVER} ${SRPM}"
	done

	# Install the built kmod RPMs as root
	dnf install -y \
		/var/lib/akmods/kmod-slimbook-qc71-${KVER}-*.rpm \
		/var/lib/akmods/kmod-slimbook-yt6801-${KVER}-*.rpm

	# Verify modules landed where the kernel expects them
	ls -la /usr/lib/modules/${KVER}/extra/ || echo "Checking module location..."

	# Drop kernel-devel to save space; modules are already compiled
	dnf remove -y kernel-devel
	dnf clean all
EOF

# Customize os-release for bootloader branding with Slimbook package digest
ARG SLIMBOOK_DIGEST=unknown
RUN <<-EOF
	set -eux
	CURRENT_VERSION=$(grep '^VERSION=' /usr/lib/os-release | cut -d'"' -f2)
	SLIMBOOK_SHORT=$(echo "${SLIMBOOK_DIGEST}" | cut -c1-12)
	NEW_VERSION="${CURRENT_VERSION} + Slimbook ${SLIMBOOK_SHORT}"
	sed -i "s/^NAME=.*/NAME=\"Bluefin DX Slimbook\"/" /usr/lib/os-release
	sed -i "s/^VERSION=.*/VERSION=\"${NEW_VERSION}\"/" /usr/lib/os-release
	sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Bluefin DX Slimbook (${NEW_VERSION})\"/" /usr/lib/os-release
	sed -i "s/^VARIANT_ID=.*/VARIANT_ID=bluefin-dx-slimbook/" /usr/lib/os-release
	sed -i "s|^HOME_URL=.*|HOME_URL=\"https://github.com/serandel/bluefin-dx-slimbook\"|" /usr/lib/os-release
EOF

# Standard ostree container commit
RUN ostree container commit
