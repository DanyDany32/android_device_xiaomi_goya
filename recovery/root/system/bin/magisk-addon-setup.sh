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
# This script runs from init early-boot (SELinux is already permissive on
# goya) and must never prevent recovery from booting: every failure path
# removes a partial file and exits 0.

set -u

conf=/FFiles/OF_Magisk.conf
[ -f "$conf" ] || exit 0

# shellcheck disable=SC1090
. "$conf"

case "${offset:-}" in
    ''|*[!0-9]*) exit 0 ;;
esac
case "${size:-}" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ -n "${sha256:-}" ] || exit 0
[ "$size" -gt 0 ] || exit 0

dev=/dev/block/by-name/vendor_boot
if [ ! -e "$dev" ]; then
    dev="$(find /dev/block -maxdepth 4 -name vendor_boot 2>/dev/null | head -n 1)"
fi
if [ -z "$dev" ] || [ ! -e "$dev" ]; then
    echo "magisk-addon: vendor_boot block device not found" >&2
    exit 0
fi

out=/FFiles/OF_Magisk/Magisk.zip
mkdir -p /FFiles/OF_Magisk || exit 0
rm -f "$out.tmp" "$out"

blocks=$(( (size + 4095) / 4096 ))
# The read is a few megabytes from eMMC and normally takes well under a second.
# Keep a hard timeout so a damaged partition can never stall init before the
# recovery UI starts; a failed read simply leaves the addon unavailable.
if ! timeout 20 dd if="$dev" of="$out.tmp" bs=4096 skip=$(( offset / 4096 )) \
        count="$blocks" 2>/dev/null; then
    rm -f "$out.tmp"
    exit 0
fi

# dd reads whole pages; trim the padding before publishing the file.
if ! head -c "$size" "$out.tmp" > "$out"; then
    rm -f "$out.tmp" "$out"
    exit 0
fi
rm -f "$out.tmp"

actual="$(sha256sum "$out" 2>/dev/null | awk '{print $1}')"
if [ "$actual" != "$sha256" ]; then
    echo "magisk-addon: hash mismatch (got ${actual:-none})" >&2
    rm -f "$out"
    exit 0
fi

echo "magisk-addon: $out ready ($size bytes)"
exit 0
