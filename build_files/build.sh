#!/bin/bash
set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Install packages
dnf5 -y copr enable codifryed/CoolerControl
dnf5 install -y coolercontrold coolercontrol-liqctld coolercontrol liquidctl
dnf5 -y copr disable codifryed/CoolerControl

### Build nct6687 out-of-tree module (MSI NCT6687D-R fan control)
echo "=== Building nct6687 module ==="
KVER="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
echo "=== Target kernel: ${KVER} ==="

# Only install build deps that are missing, so exactly those can be removed afterwards
BUILD_DEPS=()
for pkg in kernel-devel-matched gcc make git; do
    rpm -q "${pkg}" > /dev/null || BUILD_DEPS+=("${pkg}")
done
if [[ ${#BUILD_DEPS[@]} -gt 0 ]]; then
    dnf5 install -y "${BUILD_DEPS[@]}"
fi

# Pinned upstream commit, bumped via Renovate (customManagers in .github/renovate.json5)
NCT6687D_COMMIT="cd735225a95e04dda3e2befd94ba77e1f7609dcc"
git clone https://github.com/Fred78290/nct6687d /tmp/nct6687d
git -C /tmp/nct6687d checkout --quiet "${NCT6687D_COMMIT}"
make -C "/usr/src/kernels/${KVER}" M=/tmp/nct6687d modules

if [[ -s /ctx/MOK.priv ]]; then
    echo "=== Signing nct6687.ko with MOK key ==="
    "/usr/src/kernels/${KVER}/scripts/sign-file" sha256 \
        /ctx/MOK.priv /ctx/MOK.der /tmp/nct6687d/nct6687.ko
    modinfo /tmp/nct6687d/nct6687.ko | grep -i sig || true
else
    echo "=== WARNING: /ctx/MOK.priv not found - module will be UNSIGNED ==="
    echo "=== It will be rejected by Secure Boot at load time! ==="
fi

install -D -m 0644 /tmp/nct6687d/nct6687.ko \
    "/usr/lib/modules/${KVER}/extra/nct6687.ko"
depmod -a "${KVER}"

if [[ ${#BUILD_DEPS[@]} -gt 0 ]]; then
    dnf5 remove -y "${BUILD_DEPS[@]}"
fi

rm -rf /tmp/nct6687d
echo "=== nct6687 build complete ==="

systemctl enable podman.socket