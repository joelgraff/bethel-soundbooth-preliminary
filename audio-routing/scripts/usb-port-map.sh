#!/bin/bash
# usb-port-map.sh — Interactively map every physical USB port on this
# machine to its bus/controller, so future cable placement (e.g. for the
# PreSonus 32SX or ATEM) is a lookup instead of trial and error.
#
# Background: on 2026-09-04 the 32SX ended up sharing a USB2 controller
# ("bus" in lsusb terms) with the ATEM Mini Extreme purely because of which
# physical port it happened to be plugged into — twice, on two different
# cable swaps, discovered only after the fact (a crashed Audacity, a
# bandwidth error in dmesg). Physical port position on this case does not
# obviously correspond to xhci_hcd bus number, so there is no way to know
# which ports are safe to pair without testing each one once.
#
# Usage:
#   ./usb-port-map.sh
# Then, for each physical port in turn: plug ANY USB device into it (a
# flash drive, mouse receiver, anything) and press Enter when prompted.
# The script diffs `lsusb` before/after to find what just appeared, prints
# its bus/port path, and asks you to label the physical port (e.g. "rear
# left", "front panel top"). Ctrl-C to stop; a running log is kept so you
# can build the map over several sessions if needed.
#
# Output: appended to ~/.config/soundbooth/usb-port-map.tsv
# (tab-separated: label, bus, device-path, description, timestamp)

set -uo pipefail

OUT="${HOME}/.config/soundbooth/usb-port-map.tsv"
mkdir -p "$(dirname "$OUT")"
if [[ ! -f "$OUT" ]]; then
    printf 'label\tbus\tdevpath\tdescription\ttimestamp\n' > "$OUT"
fi

echo "USB port mapper — existing entries in $OUT:"
[[ -s "$OUT" ]] && column -t -s $'\t' "$OUT" 2>/dev/null | tail -n +1
echo
echo "For each port: unplug anything new, press Enter, THEN plug the test"
echo "device into the port you want to identify, and press Enter again."
echo "Ctrl-C any time to stop — entries so far are already saved."
echo

while true; do
    echo "----------------------------------------"
    read -r -p "Ready? Press Enter with the port EMPTY to take a baseline... " _
    BEFORE=$(lsusb 2>/dev/null | sort)

    read -r -p "Now plug the test device into the port and press Enter... " _
    sleep 1
    AFTER=$(lsusb 2>/dev/null | sort)

    NEW=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))
    if [[ -z "$NEW" ]]; then
        echo "No new device detected — didn't see a change. Try again for this port."
        continue
    fi

    echo "New device(s) detected:"
    echo "$NEW"

    # Take the first new device's bus/dev, resolve to a kernel devpath
    BUSDEV=$(echo "$NEW" | head -1 | awk '{print $2, $4}' | tr -d ':')
    BUS=$(echo "$BUSDEV" | awk '{print $1}' | sed 's/^0*//')
    DEV=$(echo "$BUSDEV" | awk '{print $2}' | sed 's/^0*//')
    DEVPATH=""
    for d in /sys/bus/usb/devices/*/; do
        if [[ -f "${d}busnum" && -f "${d}devnum" ]]; then
            b=$(cat "${d}busnum" 2>/dev/null)
            n=$(cat "${d}devnum" 2>/dev/null)
            if [[ "$b" == "$BUS" && "$n" == "$DEV" ]]; then
                DEVPATH=$(basename "$(readlink -f "$d")")
                break
            fi
        fi
    done
    echo "Bus: $BUS   Kernel path: ${DEVPATH:-unknown}"

    read -r -p "Label this physical port (e.g. 'rear top-left', or blank to skip saving): " LABEL
    if [[ -n "$LABEL" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$LABEL" "$BUS" "${DEVPATH:-unknown}" "$(echo "$NEW" | head -1 | cut -d' ' -f7-)" \
            "$(date -Iseconds)" >> "$OUT"
        echo "Saved."
    fi
    echo
done
