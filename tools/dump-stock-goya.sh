#!/usr/bin/env bash
#
# Dump the stock vendor_boot image, the four recovery-only kernel modules and
# the ODM/TEE blobs required by the OrangeFox goya device tree.
#
# Run this from a host with adb and a rooted phone:
#     tools/dump-stock-goya.sh [output.tar]
#
# The script pushes a small POSIX shell helper to the phone, runs it through
# `su`, then pulls /data/local/tmp/goya-dump.tar back. If you prefer to run the
# helper directly from a root terminal on the phone, print it with:
#     tools/dump-stock-goya.sh --print-device-script
#
set -euo pipefail

DEVICE_TAR="/data/local/tmp/goya-dump.tar"
DEVICE_HELPER="/data/local/tmp/goya-dump-device.sh"

usage() {
    cat <<'EOF'
Usage: tools/dump-stock-goya.sh [output.tar]

  output.tar                 Host path for the dump (default: goya-dump.tar).

Options:
  --print-device-script      Print the on-device POSIX helper and exit.
  -h, --help                 Show this help.

The dump contains:
  vendor_boot.img            Full vendor_boot partition of the current slot.
  meta/props.txt             Full getprop output (kept local; not committed).
  meta/build-info.txt        Selected build/slot properties for the device tree.
  meta/dump-info.txt         Dump metadata, including the block device size.
  meta/missing.txt           Optional blobs that were absent on the phone.
  files/vendor_dlkm/...      xiaomi_touch_goya.ko, nt38771_touch_goya.ko,
                             si_haptic.ko and scp.ko from vendor_dlkm.
  files/odm/...              Touch HAL, libraries, firmware and configuration.
  files/vendor/...           MiTEE KeyMint/Gatekeeper/Weaver, tee-supplicant,
                             KeyMint/TEE libraries, TA files and AW8697 firmware.
EOF
}

print_device_script() {
    cat <<'GOYA_DEVICE_SCRIPT'
#!/system/bin/sh
#
# On-device part of tools/dump-stock-goya.sh. POSIX sh only: Android's sh is
# mksh/toybox and does not provide bash arrays or pipefail.
#
set -eu

OUT="/data/local/tmp/goya-dump"
FILES="$OUT/files"
META="$OUT/meta"
TAR="/data/local/tmp/goya-dump.tar"
EXPECTED_VENDOR_BOOT_SIZE=117440512

die() {
    echo "ERROR: $*" >&2
    exit 1
}

if [ "$(id -u)" != "0" ]; then
    die "this helper must run as root (use su -c 'sh $0')"
fi

command -v getprop >/dev/null 2>&1 || die "getprop is missing"
command -v tar >/dev/null 2>&1 || die "tar is missing"
command -v dd >/dev/null 2>&1 || die "dd is missing"

rm -rf "$OUT" "$TAR" "$TAR.sha256"
mkdir -p "$FILES" "$META"
: > "$META/missing.txt"

getprop > "$META/props.txt" 2>/dev/null || true

slot="$(getprop ro.boot.slot_suffix)"
[ -n "$slot" ] || slot="_a"

VENDOR_BOOT="/dev/block/by-name/vendor_boot${slot}"
if [ ! -e "$VENDOR_BOOT" ]; then
    VENDOR_BOOT="/dev/block/by-name/vendor_boot"
fi
[ -e "$VENDOR_BOOT" ] || die "vendor_boot block device not found"

echo "Dumping vendor_boot from ${VENDOR_BOOT} (slot ${slot})"
dd if="$VENDOR_BOOT" of="$OUT/vendor_boot.img" bs=4096 2>/dev/null || \
    die "dd failed for ${VENDOR_BOOT}"

vendor_boot_size="$(wc -c < "$OUT/vendor_boot.img" | tr -d ' ')"
magic="$(dd if="$OUT/vendor_boot.img" bs=1 count=8 2>/dev/null || true)"
[ "$magic" = "VNDRBOOT" ] || die "vendor_boot.img has no VNDRBOOT magic"
if [ "$vendor_boot_size" != "$EXPECTED_VENDOR_BOOT_SIZE" ]; then
    echo "WARNING: vendor_boot is ${vendor_boot_size} bytes; expected ${EXPECTED_VENDOR_BOOT_SIZE}" >&2
fi

MODULE_DIR=""
for candidate in /vendor_dlkm/lib/modules /vendor/lib/modules /lib/modules; do
    if [ -d "$candidate" ]; then
        MODULE_DIR="$candidate"
        break
    fi
done
[ -n "$MODULE_DIR" ] || die "could not find the running vendor_dlkm module directory"

copy_file() {
    src="$1"
    dest="$FILES/${src#/}"
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest" || die "could not copy $src"
}

copy_optional() {
    src="$1"
    if [ -f "$src" ]; then
        copy_file "$src"
    else
        echo "$src" >> "$META/missing.txt"
    fi
}

copy_glob_optional() {
    pattern="$1"
    found=0
    for src in $pattern; do
        if [ -f "$src" ]; then
            copy_file "$src"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "$pattern" >> "$META/missing.txt"
    fi
}

for module in xiaomi_touch_goya.ko nt38771_touch_goya.ko si_haptic.ko scp.ko; do
    [ -f "$MODULE_DIR/$module" ] || die "missing required vendor_dlkm module: $module"
    copy_file "$MODULE_DIR/$module"
done
copy_optional "$MODULE_DIR/modules.load"
copy_optional "$MODULE_DIR/modules.dep"

# Xiaomi touchfeature HAL and Novatek TouchReport dependencies. The importer
# renames the service to vendor.xiaomi.hw.touchfeature-service-recovery.
copy_optional /odm/bin/hw/vendor.xiaomi.hw.touchfeature-service
copy_optional /odm/lib64/libtouchreport.so
copy_optional /odm/lib64/libtouchreport_alg.so
copy_optional /odm/lib64/libtouchreport_hal.so
copy_optional /odm/lib64/libtouchreport_sensor.so
copy_optional /odm/lib64/libtensorflowlite_touch_c.so
copy_glob_optional '/odm/firmware/novatek_nt38771_o12a_fw_*.bin'
copy_glob_optional '/odm/firmware/novatek_nt38771_o12a_mp_*.bin'
copy_glob_optional '/odm/firmware/o12a_nova_*_thp_config.ini'
copy_optional /odm/firmware/smooth.tflite
copy_optional /odm/firmware/water_check.tflite
copy_glob_optional '/odm/etc/touch/*.json'

# MiTEE / KeyMint / Gatekeeper / Weaver. These are optional so a Stage 1
# build (boot, touch, USB, MTP) still succeeds when the vendor blob layout
# differs between firmware regions.
copy_optional /vendor/bin/tee-supplicant
copy_optional /vendor/bin/hw/android.hardware.security.keymint@3.0-service.mitee
copy_optional /vendor/bin/hw/android.hardware.gatekeeper-service.mitee
copy_optional /vendor/bin/hw/android.hardware.weaver-service.nxp
copy_optional /vendor/etc/vintf/manifest/android.hardware.gatekeeper-service.mitee.xml
copy_optional /vendor/etc/vintf/manifest/android.hardware.security.keymint-service.mitee.xml
copy_optional /vendor/etc/vintf/manifest/android.hardware.security.secureclock-service.mitee.xml
copy_optional /vendor/etc/vintf/manifest/android.hardware.security.sharedsecret-service.mitee.xml
copy_optional /vendor/etc/vintf/manifest/android.hardware.weaver-service.nxp.xml
copy_optional /odm/etc/vintf/manifest/vendor.xiaomi.hw.touchfeature-service.xml
copy_glob_optional '/vendor/mitee/ta/*.ta'
copy_glob_optional '/odm/mitee/ta/*.ta'
# The KeyMint HAL links different versioned libraries across firmware
# releases (libkeymint.so, libkeymint_V3.so, remote provisioning helpers).
# Dump every KeyMint library and let the importer keep the exact SONAMEs.
copy_glob_optional '/vendor/lib64/*keymint*.so'
copy_optional /vendor/lib64/libteecli.so
copy_glob_optional '/vendor/lib64/libteec*.so'
copy_glob_optional '/vendor/lib64/libTEE*.so'
copy_glob_optional '/vendor/lib64/libsoft_attestation*.so'
copy_glob_optional '/vendor/lib64/libcppbor*.so'
copy_glob_optional '/vendor/lib64/*mitee*.so'
copy_glob_optional '/odm/lib64/*mitee*.so'

# AW8697 haptic firmware consumed by si_haptic.ko.
copy_glob_optional '/vendor/firmware/aw8697_*.bin'

{
    echo "dump_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    echo "slot=${slot}"
    echo "vendor_boot_device=${VENDOR_BOOT}"
    echo "vendor_boot_size=${vendor_boot_size}"
    echo "module_dir=${MODULE_DIR}"
} > "$META/dump-info.txt"

{
    for prop in \
        ro.product.device \
        ro.product.name \
        ro.product.model \
        ro.product.brand \
        ro.board.platform \
        ro.boot.hardware \
        ro.boot.slot_suffix \
        ro.boot.dynamic_partitions \
        ro.virtual_ab.enabled \
        ro.build.fingerprint \
        ro.vendor.build.fingerprint \
        ro.build.version.incremental \
        ro.build.version.security_patch \
        ro.system.build.fingerprint; do
        value="$(getprop "$prop" 2>/dev/null || true)"
        [ -n "$value" ] && echo "${prop}=${value}"
    done
} > "$META/build-info.txt"

missing_count=0
if [ -s "$META/missing.txt" ]; then
    missing_count="$(wc -l < "$META/missing.txt" | tr -d ' ')"
fi

echo "Creating ${TAR}"
( cd "$OUT" && tar -cf "$TAR" . ) || die "tar failed"
chmod 0644 "$TAR"
( cd /data/local/tmp && sha256sum goya-dump.tar > goya-dump.tar.sha256 )
chmod 0644 "$TAR.sha256"

echo "Dump ready: ${TAR}"
echo "Size:      $(wc -c < "$TAR" | tr -d ' ') bytes"
echo "SHA-256:   $(cat "$TAR.sha256" | awk '{print $1}')"
echo "Missing optional blobs: ${missing_count} (see meta/missing.txt)"
GOYA_DEVICE_SCRIPT
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --print-device-script)
        print_device_script
        exit 0
        ;;
esac

OUTPUT="${1:-goya-dump.tar}"
OUTPUT_NAME="$(basename -- "$OUTPUT")"
OUTPUT_PARENT="$(dirname -- "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_DIR="$(cd -- "$OUTPUT_PARENT" && pwd -P)"
OUTPUT="${OUTPUT_DIR}/${OUTPUT_NAME}"

for command_name in adb mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required host command not found: $command_name" >&2
        exit 1
    }
done

if ! adb get-state >/dev/null 2>&1; then
    echo "ERROR: no adb device found. Connect the phone, enable USB debugging and retry." >&2
    exit 1
fi

if ! adb shell "su -c 'id'" 2>/dev/null | grep -q 'uid=0'; then
    echo "ERROR: root through 'su' is not available. Grant root access to the shell user." >&2
    echo "If DFRoot only exposes root in its own app, run --print-device-script from a root shell." >&2
    exit 1
fi

helper="$(mktemp "${TMPDIR:-/tmp}/goya-dump-device.XXXXXX.sh")"
trap 'rm -f "$helper"' EXIT
print_device_script > "$helper"

echo "Pushing on-device dump helper"
adb push "$helper" "$DEVICE_HELPER" >/dev/null
adb shell "su -c 'sh ${DEVICE_HELPER}'"

echo "Pulling dump"
mkdir -p "$(dirname -- "$OUTPUT")"
adb pull "$DEVICE_TAR" "$OUTPUT" >/dev/null
adb pull "${DEVICE_TAR}.sha256" "${OUTPUT}.sha256" >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
    device_hash="$(awk '{print $1}' "${OUTPUT}.sha256")"
    host_hash="$(sha256sum "$OUTPUT" | awk '{print $1}')"
    if [ "$device_hash" != "$host_hash" ]; then
        echo "ERROR: pulled dump checksum does not match the on-device dump" >&2
        exit 1
    fi
    printf '%s  %s\n' "$host_hash" "$OUTPUT_NAME" > "${OUTPUT}.sha256"
fi

adb shell "su -c 'rm -rf /data/local/tmp/goya-dump /data/local/tmp/goya-dump.tar /data/local/tmp/goya-dump.tar.sha256 ${DEVICE_HELPER}'" >/dev/null 2>&1 || true

cat <<EOF

Dump saved to: ${OUTPUT}
SHA-256 file:  ${OUTPUT}.sha256

Next steps:
  1. Upload ${OUTPUT_NAME} to a GitHub release (or keep it local).
  2. Run:
       tools/import-dump.sh ${OUTPUT_NAME}
     or launch the "Prepare goya stock inputs" workflow with the release asset URL.
  3. Build with:
       .github/workflows/build-orangefox.yml
     or locally:
       build-lowmem.sh vendorbootimage
EOF
