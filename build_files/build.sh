#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

### Install packages
dnf5 -y copr enable codifryed/CoolerControl
dnf5 install -y coolercontrol liquidctl
dnf5 -y copr disable codifryed/CoolerControl

### Build nct6687 out-of-tree module (MSI NCT6687D-R fan control)
KVER="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"

dnf5 install -y kernel-devel-matched gcc make git

git clone --depth 1 https://github.com/Fred78290/nct6687d /tmp/nct6687d
make -C "/usr/src/kernels/${KVER}" M=/tmp/nct6687d modules

install -D -m 0644 /tmp/nct6687d/nct6687.ko \
    "/usr/lib/modules/${KVER}/extra/nct6687.ko"
depmod -a "${KVER}"

dnf5 remove -y kernel-devel-matched gcc make git
rm -rf /tmp/nct6687d

#### Example for enabling a System Unit File

systemctl enable podman.socket
