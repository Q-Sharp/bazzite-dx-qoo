#!/bin/bash
set -ouex pipefail

# Temporary workaround for the NVIDIA 615.71.09 regression where DisplayPort
# monitors stay black after DPMS wake or a monitor power cycle
# (https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1405).
#
# Rebuilds the NVIDIA kernel modules from the same sources as the stock Bazzite
# kmod plus the fixes in nvidia-patches/, signs them with the MOK key, replaces
# the stock modules and rebuilds the initramfs. Any other driver version keeps
# the stock modules, so this turns itself off as soon as Bazzite ships a
# different driver.
#
# Usage: nvidia-dp-fix.sh <kernel version>
# Expects kernel-devel-matched, gcc, gcc-c++, make and git to be installed.

KVER="$1"

FIX_VERSION="615.71.09"
FIX_COMMIT="61dcc93722ecb418bb5f2e00923f05b4b8051dd1"

# Patches the stock kmod is built with, in build order: negativo17
# nvidia-kmod.spec 615.71.09-2, then ublue-os/akmods patches/ogc.
# Pinned to commits so the result cannot change underneath us.
UBLUE_PATCHES="https://raw.githubusercontent.com/ublue-os/akmods/56c8acd125778251562e14e2c4182d6eddca5e44/build_files/nvidia/patches/ogc"
STOCK_PATCHES=(
    "https://github.com/anatase-org/open-gpu-kernel-modules/commit/ab2ed1443400caa8097da1107ccd0eda8e6a5354.patch"
    "https://github.com/anatase-org/open-gpu-kernel-modules/commit/2fa83dac159ee4be2f2e08be8f211aadf6a65c5c.patch"
    "${UBLUE_PATCHES}/0001-fix-dsc-correct-RC-parameter-tables-to-match-VESA-DS.patch"
    "${UBLUE_PATCHES}/0001-honor-rmdisablenoncontigalloc-in-the-pma-vidmem-path.patch"
    "${UBLUE_PATCHES}/0003-fix-dp-add-Bigscreen-Beyond-VR-headset-to-WAR-databa.patch"
)

MODDIR="/usr/lib/modules/${KVER}/extra/nvidia"
SRC="/tmp/nvidia-open"

NVIDIA_VERSION="$(modinfo -F version "${MODDIR}/nvidia.ko.xz")"
if [[ "${NVIDIA_VERSION}" != "${FIX_VERSION}" ]]; then
    echo "=== NVIDIA ${NVIDIA_VERSION}: DP fix only applies to ${FIX_VERSION} - keeping stock modules ==="
    exit 0
fi

if [[ ! -s /ctx/MOK.priv ]]; then
    echo "=== WARNING: /ctx/MOK.priv not found - keeping stock NVIDIA modules ==="
    echo "=== Unsigned NVIDIA modules would be rejected by Secure Boot (no display)! ==="
    exit 0
fi

echo "=== Rebuilding NVIDIA ${NVIDIA_VERSION} modules with DisplayPort fix ==="
git clone --depth 1 --branch "${FIX_VERSION}" \
    https://github.com/NVIDIA/open-gpu-kernel-modules "${SRC}"
if [[ "$(git -C "${SRC}" rev-parse HEAD)" != "${FIX_COMMIT}" ]]; then
    echo "ERROR: tag ${FIX_VERSION} does not point to ${FIX_COMMIT}" >&2
    exit 1
fi

for url in "${STOCK_PATCHES[@]}"; do
    curl -fsSL --retry 3 "${url}" | git -C "${SRC}" apply
done
for patch in /ctx/nvidia-patches/*.patch; do
    git -C "${SRC}" apply "${patch}"
done

make -C "${SRC}" -j"$(nproc)" KERNEL_UNAME="${KVER}" modules

# Replace exactly the modules the stock kmod ships, so the set never gets mixed
for stock in "${MODDIR}"/*.ko.xz; do
    name="$(basename "${stock}" .xz)"
    ko="${SRC}/kernel-open/${name}"
    strip --strip-debug "${ko}"
    "/usr/src/kernels/${KVER}/scripts/sign-file" sha256 \
        /ctx/MOK.priv /ctx/MOK.der "${ko}"
    xz --check=crc32 "${ko}"
    install -m 0644 "${ko}.xz" "${stock}"
    signer="$(modinfo -F signer "${stock}")"
    if [[ -z "${signer}" ]]; then
        echo "ERROR: ${name} is not signed" >&2
        exit 1
    fi
done
depmod -a "${KVER}"

# The initramfs carries its own copy of the NVIDIA modules and loads them first
# (force_drivers in dracut.conf.d/99-nvidia.conf), so rebuild it the way
# bazzite-dx does. /root points to /var/roothome, which dracut only picks up
# if it exists during the build.
mkdir -p /var/roothome
dracut --no-hostonly --kver "${KVER}" --reproducible --zstd --add ostree \
    -f "/usr/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"
rmdir --ignore-fail-on-non-empty /var/roothome

rm -rf "${SRC}"
echo "=== NVIDIA rebuild complete ==="
