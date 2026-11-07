#!/usr/bin/env bash
#
# Extract the stock vendor_boot platform fragment, DTB, bootconfig and ramdisk
# table from a vendor_boot image. The resulting prebuilt/vendor-boot directory
# is the immutable input used by tools/build-system-compatible-vendor-boot.sh.
#
# Usage:
#   tools/prepare-stock-vendor-boot.sh [vendor_boot.img]
#
# The default input is prebuilt/vendor_boot_stock.img. That file is ignored by
# Git because it is the full 112 MiB partition; only the extracted platform
# fragment, DTB, bootconfig and header.json are committed.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNPACK_PY="${DEVICE_DIR}/tools/unpack-vendor-boot.py"
PREBUILT_DIR="${DEVICE_DIR}/prebuilt/vendor-boot"
DTB_DEST="${DEVICE_DIR}/prebuilt/dtb/mt6899-goya.dtb"
EXPECTED_VENDOR_BOOT_SIZE=117440512
PYTHON="${PYTHON:-python3}"

usage() {
    cat <<'EOF'
Usage: tools/prepare-stock-vendor-boot.sh [vendor_boot.img]

  vendor_boot.img       Stock vendor_boot image. Defaults to
                        prebuilt/vendor_boot_stock.img.

Extracts:
  prebuilt/vendor-boot/vendor_ramdisk00   Type-1 platform fragment (stock)
  prebuilt/vendor-boot/vendor_ramdisk01+  Any extra stock fragments
  prebuilt/vendor-boot/modules.load.recovery
                                          First-stage recovery module list,
                                          read from the platform fragment
                                          (fallback: recovery fragment)
  prebuilt/vendor-boot/dtb                Stock DTB
  prebuilt/vendor-boot/bootconfig         Stock bootconfig (may be empty)
  prebuilt/vendor-boot/header.json        Vendor_boot v4 ramdisk table
  prebuilt/dtb/mt6899-goya.dtb            Copy used by the repacker/Make
  prebuilt/vendor_boot_stock.sha256       Hash of the source image
EOF
}

INPUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$INPUT" ]; then
                echo "ERROR: only one input image may be specified" >&2
                exit 2
            fi
            INPUT="$1"
            ;;
    esac
    shift
done

INPUT="${INPUT:-${DEVICE_DIR}/prebuilt/vendor_boot_stock.img}"

for command_name in cpio dd find gzip od stat sha256sum awk grep; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required host command not found: $command_name" >&2
        exit 1
    }
done
[ -f "$UNPACK_PY" ] || {
    echo "ERROR: missing unpacker: $UNPACK_PY" >&2
    exit 1
}
"$PYTHON" -c 'import sys; sys.exit(0)' >/dev/null 2>&1 || {
    echo "ERROR: Python interpreter not found: $PYTHON" >&2
    echo "Set PYTHON=/path/to/python3 if it is installed under another name." >&2
    exit 1
}
[ -f "$INPUT" ] || {
    echo "ERROR: vendor_boot image not found: $INPUT" >&2
    echo "Run tools/dump-stock-goya.sh or point this script at the stock vendor_boot.img." >&2
    exit 1
}

input_size="$(stat -c %s "$INPUT")"
magic="$(dd if="$INPUT" bs=1 count=8 2>/dev/null || true)"
[ "$magic" = "VNDRBOOT" ] || {
    echo "ERROR: input is not a vendor_boot image (no VNDRBOOT magic): $INPUT" >&2
    exit 1
}
if [ "$input_size" -ne "$EXPECTED_VENDOR_BOOT_SIZE" ]; then
    echo "WARNING: vendor_boot is ${input_size} bytes; goya's partition is ${EXPECTED_VENDOR_BOOT_SIZE}." >&2
    echo "WARNING: extraction can still succeed if every header section is complete." >&2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/goya-vendor-boot-prepare.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

echo "Unpacking ${INPUT}"
"$PYTHON" "$UNPACK_PY" --input "$INPUT" --out "$work_dir"

"$PYTHON" - "$work_dir" <<'PY'
import json
import os
import sys

root = sys.argv[1]
header_path = os.path.join(root, "header.json")
with open(header_path, encoding="utf-8") as handle:
    info = json.load(handle)

if info.get("header_version") != 4:
    raise SystemExit(f"vendor_boot header v{info.get('header_version')} is not supported")
if info.get("page_size") != 4096:
    raise SystemExit(f"unexpected vendor_boot page size: {info.get('page_size')}")

entries = info.get("ramdisk_table") or []
if not entries:
    raise SystemExit("vendor_boot has no ramdisk table entries")

platforms = [entry for entry in entries if entry.get("type_name") == "platform" and entry.get("size", 0) > 0]
if not platforms:
    raise SystemExit("vendor_boot has no non-empty platform ramdisk fragment")

for entry in entries:
    fragment = os.path.join(root, entry["file"])
    if not os.path.isfile(fragment):
        raise SystemExit(f"missing extracted fragment: {fragment}")
    actual = os.path.getsize(fragment)
    if actual != entry["size"]:
        raise SystemExit(f"fragment size mismatch for {entry['file']}: {actual} != {entry['size']}")

dtb_path = os.path.join(root, "dtb")
if not os.path.isfile(dtb_path) or os.path.getsize(dtb_path) < 64:
    raise SystemExit("vendor_boot DTB is missing or too small")
with open(dtb_path, "rb") as handle:
    dtb = handle.read(0x44)
if dtb[:4] == b"\xd0\x0d\xfe\xed":
    dtb_kind = "plain FDT"
elif len(dtb) >= 0x44 and dtb[0x40:0x44] == b"\xd0\x0d\xfe\xed":
    dtb_kind = "MediaTek-wrapped FDT"
else:
    raise SystemExit("vendor_boot DTB has no FDT magic at 0x00 or 0x40")

bootconfig_path = os.path.join(root, "bootconfig")
bootconfig_size = os.path.getsize(bootconfig_path) if os.path.isfile(bootconfig_path) else 0
if bootconfig_size != info.get("bootconfig_size", 0):
    raise SystemExit("bootconfig size does not match the vendor_boot header")

print(f"header v{info['header_version']}, page size {info['page_size']}")
print(f"vendor cmdline: {info.get('vendor_cmdline')!r}")
print(f"DTB: {os.path.getsize(dtb_path)} bytes ({dtb_kind})")
print(f"bootconfig: {bootconfig_size} bytes")
for entry in entries:
    print(f"  {entry['file']}: type={entry['type_name']} name={entry['name']!r} size={entry['size']}")
PY

# The stock recovery fragment on goya contains no kernel modules: the exact
# first-stage list (lib/modules/modules.load.recovery) lives in the platform
# fragment, i.e. vendor_ramdisk00. It includes the MTK IPI/RPMSG mailbox
# modules that the normal-boot modules.load omits. Keep a copy so
# fox_callback.sh can install it in the OrangeFox recovery fragment. Some
# other layouts put the list in the recovery fragment, so that is the fallback.
decompress_fragment() {
    local input="$1" output="$2" magic

    magic="$(od -An -tx1 -N4 "$input" | tr -d ' \n')"
    case "$magic" in
        02214c18|04224d18)
            command -v lz4 >/dev/null 2>&1 || return 1
            lz4 -d -f "$input" "$output" >/dev/null
            ;;
        1f8b*)
            gzip -dc "$input" > "$output"
            ;;
        30373037*)
            cp -f "$input" "$output"
            ;;
        *)
            return 1
            ;;
    esac
}

read_fragment_name() {
    "$PYTHON" - "$work_dir/header.json" "$1" <<'PY'
import json
import sys

path, kind = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    info = json.load(handle)
entry = next(
    (item for item in info.get("ramdisk_table", [])
     if item.get("type_name") == kind and item.get("size", 0) > 0),
    None,
)
if entry is not None:
    print(entry["file"])
PY
}

platform_file="$(read_fragment_name platform || true)"
recovery_file="$(read_fragment_name recovery || true)"

# Extract lib/modules/modules.load.recovery from one fragment. Returns
# 0 on success, 2 when the archive has no such entry and 1 when the
# fragment cannot be decompressed.
extract_module_list() {
    local fragment="$1" cpio_file="$2" entry

    [ -n "$fragment" ] && [ -f "${work_dir}/${fragment}" ] || return 1
    decompress_fragment "${work_dir}/${fragment}" "$cpio_file" || return 1
    entry="$(cpio -it --quiet < "$cpio_file" | \
        grep -E '^(\./)?lib/modules/modules\.load\.recovery$' | head -n 1 || true)"
    [ -n "$entry" ] || return 2
    rm -f "${work_dir}/modules.load.recovery"
    cpio -i --quiet --to-stdout "$entry" < "$cpio_file" \
        > "${work_dir}/modules.load.recovery" || return 1
    return 0
}

module_list_source=""
module_list_status=1
if [ -n "${platform_file:-}" ]; then
    platform_cpio="${work_dir}/stock-platform.cpio"
    if extract_module_list "$platform_file" "$platform_cpio"; then
        module_list_source="platform fragment"
        module_list_status=0
    else
        module_list_status=$?
        if [ "$module_list_status" -eq 2 ]; then
            echo "WARNING: platform fragment has no lib/modules/modules.load.recovery" >&2
        else
            echo "WARNING: cannot decompress the platform fragment; install lz4 to preserve its module list" >&2
        fi
    fi
    rm -f "$platform_cpio"
fi

if [ "$module_list_status" -ne 0 ] && [ -n "${recovery_file:-}" ]; then
    recovery_cpio="${work_dir}/stock-recovery.cpio"
    if extract_module_list "$recovery_file" "$recovery_cpio"; then
        module_list_source="recovery fragment"
        module_list_status=0
    else
        module_list_status=$?
        if [ "$module_list_status" -eq 2 ]; then
            echo "WARNING: stock recovery fragment has no lib/modules/modules.load.recovery" >&2
        else
            echo "WARNING: cannot decompress the stock recovery fragment; install lz4 to preserve its module list" >&2
        fi
    fi
    rm -f "$recovery_cpio"
fi

if [ "$module_list_status" -eq 0 ]; then
    echo "Stock recovery module list: $(wc -l < "${work_dir}/modules.load.recovery" | tr -d ' ') entries (from ${module_list_source})"
else
    echo "WARNING: no stock modules.load.recovery could be extracted" >&2
fi
magic4="$(od -An -tx1 -N4 "$work_dir/$platform_file" | tr -d ' \n')"
case "$magic4" in
    02214c18|04224d18|1f8b*|30373037)
        ;;
    *)
        echo "ERROR: unsupported platform ramdisk compression (magic ${magic4})" >&2
        exit 1
        ;;
esac

mkdir -p "$PREBUILT_DIR" "$(dirname -- "$DTB_DEST")"
# Replace only generated contents. The directory is dedicated to the stock
# platform fragment and must not retain files from a previous firmware dump.
find "$PREBUILT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "$work_dir/." "$PREBUILT_DIR/"

dtb_tmp="${DTB_DEST}.tmp.$$"
cp -f "$work_dir/dtb" "$dtb_tmp"
mv -f "$dtb_tmp" "$DTB_DEST"

input_sha256="$(sha256sum "$INPUT" | awk '{print $1}')"
printf '%s  %s\n' "$input_sha256" "$(basename -- "$INPUT")" \
    > "${DEVICE_DIR}/prebuilt/vendor_boot_stock.sha256"

echo
echo "Stock vendor_boot inputs prepared:"
echo "  platform fragment : ${PREBUILT_DIR}/${platform_file}"
echo "  DTB               : ${DTB_DEST}"
echo "  bootconfig        : ${PREBUILT_DIR}/bootconfig"
echo "  header            : ${PREBUILT_DIR}/header.json"
if [ -f "${PREBUILT_DIR}/modules.load.recovery" ]; then
    echo "  recovery modules  : ${PREBUILT_DIR}/modules.load.recovery"
fi
echo
echo "Next: tools/import-dump.sh <dump.tar> (for modules/blobs) or"
echo "      tools/generate-blobs-mk.sh && tools/verify-build-inputs.sh"
