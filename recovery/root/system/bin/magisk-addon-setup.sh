#!/system/bin/sh
#
# Copy the Magisk installer APK from the unused tail of the vendor_boot
# partition to the path used by the OrangeFox Magisk addon.
#
# The APK is embedded in the release image by
# tools/build-system-compatible-vendor-boot.sh because the 64 MB vendor
# ramdisk has no room for it. /FFiles/OF_Magisk.conf carries the offset, size
# and SHA-256 that were used at build time.
#
# This script runs as the magisk-addon-setup oneshot service (SELinux is
# already permissive on goya) and must never prevent recovery from booting:
# every failure path removes a partial file and exits 0. ueventd publishes
# the slot-specific by-name symlink several seconds after early-boot, so the
# service polls for it instead of assuming the generic vendor_boot name is
# already present.

set -u

conf=/FFiles/OF_Magisk.conf
log=/FFiles/OF_Magisk.log

now() {
    read -r up _ < /proc/uptime 2>/dev/null || up=?
    echo "$up"
}

# Log to the kernel ring buffer as well: /FFiles is available from the
# ramdisk in normal boots, but kmsg keeps the reason visible even if a future
# image layout starts recovery before the ramdisk overlay is complete.
log_msg() {
    echo "magisk-addon: $(now)s $*" > /dev/kmsg 2>/dev/null
    echo "magisk-addon: $(now)s $*" >> "$log" 2>/dev/null
}

log_msg "start pid=$$"

slot=""
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        androidboot.slot_suffix=*) slot="${arg#androidboot.slot_suffix=}" ;;
    esac
done
if [ -z "$slot" ]; then
    slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
fi
log_msg "slot=${slot:-none}"

i=0
while [ ! -f "$conf" ] && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
done
if [ ! -f "$conf" ]; then
    log_msg "$conf not found after ${i} polls"
    exit 0
fi

# shellcheck disable=SC1090
. "$conf"

case "${offset:-}" in
    ''|*[!0-9]*) log_msg "invalid offset"; exit 0 ;;
esac
case "${size:-}" in
    ''|*[!0-9]*) log_msg "invalid size"; exit 0 ;;
esac
if [ -z "${sha256:-}" ] || [ "$size" -le 0 ]; then
    log_msg "invalid sha256/size"
    exit 0
fi

find_by_name() {
    for name in "vendor_boot$slot" vendor_boot; do
        [ -n "$name" ] || continue
        for dir in /dev/block/by-name /dev/block/platform/*/by-name; do
            if [ -e "$dir/$name" ]; then
                echo "$dir/$name"
                return 0
            fi
        done
    done
    return 1
}

# ueventd creates the raw block node during first-stage coldboot, while the
# by-name symlinks can appear much later. Read PARTNAME/DEVNAME from sysfs so
# the correct slot is found even before /dev/block/by-name exists.
find_by_sysfs() {
    for uevent in /sys/class/block/*/uevent; do
        [ -e "$uevent" ] || continue
        part=""
        devname=""
        while IFS='=' read -r key value; do
            case "$key" in
                PARTNAME) part="$value" ;;
                DEVNAME) devname="$value" ;;
            esac
        done < "$uevent" 2>/dev/null
        [ -n "$devname" ] || continue
        if [ -n "$slot" ]; then
            [ "$part" = "vendor_boot$slot" ] || continue
        else
            case "$part" in
                vendor_boot|vendor_boot_*) ;;
                *) continue ;;
            esac
        fi
        if [ -e "/dev/block/$devname" ]; then
            echo "/dev/block/$devname"
            return 0
        fi
    done
    return 1
}

dev=""
i=0
while [ "$i" -lt 100 ]; do
    dev="$(find_by_name)" || dev=""
    if [ -z "$dev" ] && [ $((i % 5)) -eq 0 ]; then
        dev="$(find_by_sysfs)" || dev=""
    fi
    [ -n "$dev" ] && break
    sleep 0.2
    i=$((i + 1))
done

if [ -z "$dev" ] || [ ! -e "$dev" ]; then
    log_msg "vendor_boot block device not found after ${i} polls"
    exit 0
fi
log_msg "using $dev after ${i} polls"

out=/FFiles/OF_Magisk/Magisk.zip
mkdir -p /FFiles/OF_Magisk || exit 0
rm -f "$out.tmp" "$out"

blocks=$(( (size + 4095) / 4096 ))
# The read is a few megabytes from eMMC and normally takes well under a second.
# Keep a hard timeout so a damaged partition can never stall the service; a
# failed read simply leaves the addon unavailable.
if ! timeout 20 dd if="$dev" of="$out.tmp" bs=4096 skip=$(( offset / 4096 )) \
        count="$blocks" 2>/dev/null; then
    log_msg "dd failed reading $dev"
    rm -f "$out.tmp"
    exit 0
fi

# dd reads whole pages; trim the padding before publishing the file.
if ! head -c "$size" "$out.tmp" > "$out"; then
    log_msg "head failed trimming $out.tmp"
    rm -f "$out.tmp" "$out"
    exit 0
fi
rm -f "$out.tmp"
chmod 0644 "$out" 2>/dev/null || true

actual="$(sha256sum "$out" 2>/dev/null | awk '{print $1}')"
if [ "$actual" != "$sha256" ]; then
    log_msg "hash mismatch (got ${actual:-none})"
    rm -f "$out"
    exit 0
fi

log_msg "$out ready ($size bytes)"
exit 0
