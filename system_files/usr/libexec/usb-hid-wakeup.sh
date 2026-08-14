#!/usr/bin/bash
# Allow USB HID devices (keyboards, mice, ...) to wake the machine from suspend.
#
# Walks every USB interface with bInterfaceClass 03 (HID) and enables
# power/wakeup on its parent USB device. Run once at boot by
# usb-hid-wakeup.service and again on every HID hotplug, triggered by
# /usr/lib/udev/rules.d/90-usb-input-wakeup.rules.
#
# Deliberately no `set -e`: a device that does not support wakeup must not
# abort the pass for all the others.
set -uo pipefail

shopt -s nullglob

rc=0

for class_file in /sys/bus/usb/devices/*/bInterfaceClass; do
    [[ "$(<"${class_file}")" == "03" ]] || continue

    iface="$(dirname "${class_file}")"
    device="$(dirname "$(readlink -f "${iface}")")"
    wakeup="${device}/power/wakeup"

    # Devices whose controller cannot signal wakeup have no such attribute
    [[ -w "${wakeup}" ]] || continue
    [[ "$(<"${wakeup}")" == "enabled" ]] && continue

    name="$(cat "${device}/product" 2> /dev/null || echo "unknown device")"
    if echo enabled > "${wakeup}" 2> /dev/null; then
        echo "enabled wakeup for ${device##*/} (${name})"
    else
        echo "failed to enable wakeup for ${device##*/} (${name})" >&2
        rc=1
    fi
done

exit "${rc}"
