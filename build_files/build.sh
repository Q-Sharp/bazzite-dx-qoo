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
for pkg in kernel-devel-matched gcc gcc-c++ make git; do
    rpm -q "${pkg}" > /dev/null || BUILD_DEPS+=("${pkg}")
done
if [[ ${#BUILD_DEPS[@]} -gt 0 ]]; then
    dnf5 install -y "${BUILD_DEPS[@]}"
fi

git clone --depth 1 https://github.com/Fred78290/nct6687d /tmp/nct6687d
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

# Ship the public MOK so users can enroll it (ujust enroll-nct6687-signing-key)
install -D -m 0644 /ctx/MOK.der /etc/pki/mok/MOK.der

### Rebuild the NVIDIA modules with the DisplayPort fix (affected driver version only)
/ctx/nvidia-dp-fix.sh "${KVER}"

### Turn off the cgroup-based VRAM accounting added in NVIDIA driver 615
# With Bazzite's dmemcg-booster running, driver 615 reports only about 4 GB of
# VRAM to games. RmMemacctMode=0 disables the accounting; older drivers ignore
# the key. NVreg_RegistryDwords is one string and the last "options" line wins,
# so carry over whatever the base image already sets.
NV_DWORDS="$(sed -n 's/^options nvidia .*NVreg_RegistryDwords="\{0,1\}\([^" ]*\).*/\1/p' \
    /usr/lib/modprobe.d/*.conf | tail -n 1)"
echo "options nvidia NVreg_RegistryDwords=\"${NV_DWORDS:+${NV_DWORDS};}RmMemacctMode=0\"" \
    > /usr/lib/modprobe.d/zz-nvidia-memacct.conf

if [[ ${#BUILD_DEPS[@]} -gt 0 ]]; then
    dnf5 remove -y "${BUILD_DEPS[@]}"
fi

rm -rf /tmp/nct6687d
echo "=== nct6687 build complete ==="

### Rebuild the initramfs
# It carries its own copy of the NVIDIA modules and of modprobe.d and loads the
# modules from there (force_drivers in dracut.conf.d/99-nvidia.conf), so changes
# to either only take effect after a rebuild. Same dracut call as bazzite-dx.
# /root points to /var/roothome, which dracut only picks up if it exists.
mkdir -p /var/roothome
dracut --no-hostonly --kver "${KVER}" --reproducible --zstd --add ostree \
    -f "/usr/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"
rmdir --ignore-fail-on-non-empty /var/roothome

systemctl enable podman.socket

### Verify final image and contents are correct.
bootc container lint
