#!/usr/bin/bash
# Allow USB HID devices (keyboards, mice, ...) to wake the machine from suspend,
# and keep the hubs they hang off of out of runtime autosuspend.
#
# Two passes per HID interface (bInterfaceClass 03):
#   1. power/wakeup = enabled on the owning USB device, so a keypress can
#      resume the machine.
#   2. power/control = on for that device and every USB device up the chain
#      to the root hub, so the kernel does not runtime-suspend a hub whose
#      children are supposed to stay responsive. Cheap hub firmware (KVM
#      switches in particular) tends to wedge when suspended underneath an
#      active device.
#
# Run once at boot by usb-hid-wakeup.service and again on every HID hotplug,
# triggered by /usr/lib/udev/rules.d/90-usb-input-wakeup.rules.
#
# Deliberately no `set -e`: a device that does not support wakeup or runtime
# power management must not abort the pass for all the others.

set -uo pipefail
shopt -s nullglob

rc=0

# Enable remote wakeup on a USB device directory.
enable_wakeup() {
    local device="$1"
    local wakeup="${device}/power/wakeup"
    local name

    # Devices whose controller cannot signal wakeup have no such attribute
    [[ -w "${wakeup}" ]] || return 0
    [[ "$(<"${wakeup}")" == "enabled" ]] && return 0

    name="$(cat "${device}/product" 2> /dev/null || echo "unknown device")"

    if echo enabled > "${wakeup}" 2> /dev/null; then
        echo "enabled wakeup for ${device##*/} (${name})"
    else
        echo "failed to enable wakeup for ${device##*/} (${name})" >&2
        return 1
    fi
}

# Pin a single USB device to power/control = on (no runtime autosuspend).
pin_powered() {
    local device="$1"
    local control="${device}/power/control"
    local name

    [[ -w "${control}" ]] || return 0
    [[ "$(<"${control}")" == "on" ]] && return 0

    name="$(cat "${device}/product" 2> /dev/null || echo "unknown device")"

    if echo on > "${control}" 2> /dev/null; then
        echo "pinned power/control=on for ${device##*/} (${name})"
    else
        echo "failed to pin power/control for ${device##*/} (${name})" >&2
        return 1
    fi
}

# Walk from a USB device up to its root hub, pinning every hop.
# USB device directories carry bDeviceClass; interfaces carry bInterfaceClass;
# the PCI controller above the root hub has neither, which ends the walk.
pin_chain() {
    local node="$1"

    while [[ -f "${node}/bDeviceClass" ]]; do
        pin_powered "${node}" || rc=1
        node="$(dirname "${node}")"
    done
}

for class_file in /sys/bus/usb/devices/*/bInterfaceClass; do
    [[ "$(<"${class_file}")" == "03" ]] || continue

    iface="$(dirname "${class_file}")"
    device="$(dirname "$(readlink -f "${iface}")")"

    enable_wakeup "${device}" || rc=1
    pin_chain "${device}"
done

exit "${rc}"