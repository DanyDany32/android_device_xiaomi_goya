#!/usr/bin/env bash
#
# Merge the OrangeFox recovery fragment produced by `mka vendorbootimage` with
# the stock vendor_boot platform fragment extracted from the phone.
#
# A plain `vendorbootimage` build on goya is recovery-only and must never be
# flashed: the display, USB and storage modules live in the stock platform
# ramdisk. This script recreates the full vendor_boot v4 layout and appends the
# stock platform DTB plus an AVB hash footer.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOP_DIR="$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)"
PRODUCT_OUT="${1:-${OUT_DIR:-${TOP_DIR}/out}/target/product/goya}"
PREBUILT_DIR="${DEVICE_DIR}/prebuilt/vendor-boot"
STOCK_PLATFORM_JSON="${PREBUILT_DIR}/header.json"

OUTPUT_IMAGE="${2:-${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya-system-compatible.img}"
DISABLE_AVB_OUTPUT_IMAGE="${3:-${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya-disable-avb-system-compatible.img}"

STOCK_DTB="${DEVICE_DIR}/prebuilt/dtb/mt6899-goya.dtb"
RECOVERY_LZ4="${PRODUCT_OUT}/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
HOST_LZ4="${PRODUCT_OUT%/target/product/goya}/host/linux-x86/bin/lz4"
MKBOOTIMG="${PRODUCT_OUT%/target/product/goya}/host/linux-x86/bin/mkbootimg"
MKBOOTFS="${PRODUCT_OUT%/target/product/goya}/host/linux-x86/bin/mkbootfs"
AVBTOOL="${PRODUCT_OUT%/target/product/goya}/host/linux-x86/bin/avbtool"
UNPACK_BOOTIMG="${DEVICE_DIR}/tools/unpack-vendor-boot.py"
DTB_PATCHER="${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py"

for file in "$STOCK_DTB" "$RECOVERY_LZ4" "$MKBOOTIMG" "$MKBOOTFS" \
            "$AVBTOOL" "$UNPACK_BOOTIMG" "$DTB_PATCHER"; do
    if [ ! -f "$file" ]; then
        echo "missing required build input: $file" >&2
        echo "run tools/prepare-stock-vendor-boot.sh with the stock vendor_boot.img first" >&2
        exit 1
    fi
done

# The AOSP host lz4 is always built together with mkbootimg, but allow a
# distribution lz4 as a fallback so the repack can also run outside a full
# AOSP host-tools build.
if [ -x "$HOST_LZ4" ]; then
    LZ4="$HOST_LZ4"
elif command -v lz4 >/dev/null 2>&1; then
    LZ4="$(command -v lz4)"
else
    echo "missing required host command: lz4" >&2
    exit 1
fi
if [ ! -f "$STOCK_PLATFORM_JSON" ]; then
    echo "missing stock vendor_boot description: $STOCK_PLATFORM_JSON" >&2
    echo "run tools/prepare-stock-vendor-boot.sh with the stock vendor_boot.img first" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || {
    echo "missing required host command: python3" >&2
    exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/goya-vendor-boot.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

recovery_cpio="${work_dir}/recovery.cpio"
platform_cpio="${work_dir}/platform.cpio"
platform_root="${work_dir}/platform-root"
platform_pruned_cpio="${work_dir}/platform-pruned.cpio"
platform_pruned_lz4="${work_dir}/platform-pruned.cpio.lz4"
disable_avb_platform_root="${work_dir}/platform-disable-avb-root"
disable_avb_platform_cpio="${work_dir}/platform-disable-avb.cpio"
disable_avb_platform_lz4="${work_dir}/platform-disable-avb.cpio.lz4"
unsigned_image="${work_dir}/vendor_boot.img"
disable_avb_unsigned_image="${work_dir}/vendor_boot-disable-avb.img"
disable_avb_bootconfig="${work_dir}/vendor_boot-disable-avb.bootconfig"
disable_avb_inspect_dir="${work_dir}/vendor_boot-disable-avb-inspect"
standard_inspect_dir="${work_dir}/vendor_boot-standard-inspect"
disable_avb_verify_image="${work_dir}/vendor_boot.img"
patched_dtb="${work_dir}/mt6899-goya-no-usb-offload.dtb"

read_json_value() {
    python3 - "$STOCK_PLATFORM_JSON" "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for key in sys.argv[2].split("."):
    if isinstance(value, list):
        if key == "__len__":
            value = len(value)
        else:
            value = value[int(key)]
    else:
        value = value[key]
print(value)
PY
}

read_platform_index() {
    python3 - "$STOCK_PLATFORM_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for index, item in enumerate(data.get("ramdisk_table", [])):
    if item.get("type_name") == "platform" and item.get("size", 0) > 0:
        print(index)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

read_platform_value() {
    python3 - "$STOCK_PLATFORM_JSON" "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
entry = next(
    (item for item in data.get("ramdisk_table", [])
     if item.get("type_name") == "platform" and item.get("size", 0) > 0),
    None,
)
if entry is None:
    raise SystemExit(1)
print(entry[sys.argv[2]])
PY
}

VENDOR_CMDLINE="$(read_json_value vendor_cmdline)"
DTB_ADDR="$(read_json_value dtb_addr)"
BOARD_NAME="$(read_json_value name)"
if [ -z "$VENDOR_CMDLINE" ]; then
    VENDOR_CMDLINE="bootopt=64S3,32N2,64N2"
fi

# mkbootimg writes dtb_addr as base + dtb_offset. Warn early if the stock
# header used a different absolute address so a mismatch is not discovered
# only after flashing.
calculated_dtb_addr=$((0x3fff8000 + 0x07c88000))
if [ -n "${DTB_ADDR}" ] && [ "${DTB_ADDR}" != "${calculated_dtb_addr}" ]; then
    echo "warning: stock vendor_boot dtb_addr ${DTB_ADDR} differs from repack address ${calculated_dtb_addr}" >&2
fi

# Android's USB audio offload node (mediatek,usb-offload) makes mtu3 reject
# host-mode transitions until an audio/MD stack registers an offload provider.
# Recovery does not run that stack, so remove only this optional xHCI property
# from a temporary DTB.
python3 "$DTB_PATCHER" --input "$STOCK_DTB" --output "$patched_dtb" --allow-missing

decompress_ramdisk() {
    local input="$1"
    local output="$2"
    local magic
    magic="$(od -An -tx1 -N4 "$input" | tr -d ' \n')"
    case "$magic" in
        02214c18|04224d18)
            "$LZ4" -d -f "$input" "$output" >/dev/null
            ;;
        1f8b*)
            gzip -dc "$input" > "$output"
            ;;
        30373037*)
            cp -f "$input" "$output"
            ;;
        *)
            echo "unsupported vendor ramdisk compression (magic ${magic}): $input" >&2
            exit 1
            ;;
    esac
}

# The first non-empty platform fragment carries the stock recovery userspace,
# fstab and kernel modules. It is not guaranteed to be table entry 0, so locate
# it by type. Additional platform/dlkm fragments are passed through untouched.
PLATFORM_INDEX="$(read_platform_index 2>/dev/null || true)"
PLATFORM_FILE="$(read_platform_value file 2>/dev/null || true)"
if [ -z "$PLATFORM_INDEX" ] || [ -z "$PLATFORM_FILE" ]; then
    echo "stock vendor_boot has no platform ramdisk fragment" >&2
    exit 1
fi
STOCK_RAMDISK="${PREBUILT_DIR}/${PLATFORM_FILE}"
if [ ! -f "$STOCK_RAMDISK" ]; then
    echo "missing stock platform ramdisk: $STOCK_RAMDISK" >&2
    exit 1
fi

"$LZ4" -d -f "$RECOVERY_LZ4" "$recovery_cpio" >/dev/null
decompress_ramdisk "$STOCK_RAMDISK" "$platform_cpio"

if cpio -it --quiet < "$recovery_cpio" | \
        grep -Eq '^(\./)?(system|vendor)/etc/vintf/manifest/android\.hardware\.health-service\.example\.xml$'; then
    echo "recovery ramdisk still declares the unavailable AIDL Health service" >&2
    exit 1
fi

verify_recovery_elf() {
    local cpio_file="$1" archive_path="$2" extracted_file

    extracted_file="${work_dir}/$(basename "$archive_path")"
    if ! cpio -it --quiet < "$cpio_file" | grep -E "^(\./)?${archive_path}$" >/dev/null; then
        echo "recovery ramdisk is missing required ELF: $archive_path" >&2
        exit 1
    fi
    cpio -i --quiet --to-stdout "$archive_path" < "$cpio_file" > "$extracted_file"
    python3 - "$extracted_file" "$archive_path" <<'PY'
import pathlib
import sys
library = pathlib.Path(sys.argv[1])
archive_path = sys.argv[2]
if library.read_bytes()[:4] != b"\x7fELF":
    raise SystemExit(f"recovery ramdisk has invalid ELF: {archive_path}")
PY
}

verify_recovery_elf "$recovery_cpio" system/lib64/libprocessgroup_setup.so

module_count="$(cpio -it --quiet < "$recovery_cpio" | awk '/^lib\/modules\/.*\.ko$/ { count++ } END { print count + 0 }')"
if [ "$module_count" -gt 7 ]; then
    echo "recovery fragment still contains $module_count modules; expected at most 7" >&2
    exit 1
fi

if [ -s "${PREBUILT_DIR}/modules.load.recovery" ] && \
        ! cpio -it --quiet < "$recovery_cpio" | \
            grep -Eq '^(\./)?lib/modules/modules\.load\.recovery$'; then
    echo "recovery fragment is missing the stock modules.load.recovery" >&2
    echo "check that fox_callback.sh copied it from prebuilt/vendor-boot" >&2
    exit 1
fi

# The stock platform fragment also contains a complete stock-recovery
# userspace. Normal Android boot never uses these files after /system is
# mounted, and the OrangeFox recovery fragment supplies its own copies. Keep
# first-stage init, linker/runtime, SELinux policy, fstab, firmware, every
# kernel module and the MediaTek AIDL BootControl binary.
mkdir -p "$platform_root"
(
    cd "$platform_root"
    cpio -idm --quiet --no-absolute-filenames < "$platform_cpio"
)

# Relocate every device VINTF fragment from /system to /vendor. A device
# manifest below /system is parsed as a framework fragment by servicemanager,
# which prevents Keystore2 from registering and leaves metadata decryption
# waiting forever.
if [ -d "$platform_root/system/etc/vintf/manifest" ]; then
    mkdir -p "$platform_root/vendor/etc/vintf/manifest"
    while IFS= read -r -d '' manifest; do
        if grep -q 'type="device"' "$manifest"; then
            mv "$manifest" "$platform_root/vendor/etc/vintf/manifest/$(basename "$manifest")"
        fi
    done < <(find "$platform_root/system/etc/vintf/manifest" -maxdepth 1 -type f -name '*.xml' -print0)
fi

# The stock BootControl service is AIDL on goya. The module name differs
# between MTK firmware branches; accept both spellings. The recovery rc file
# is replaced by device_xiaomi_goya/recovery/root/init.recovery.bootctl.rc so
# the libc++ compatibility shim is preloaded.
boot_control_found=0
for service in \
    "$platform_root/system/bin/hw/android.hardware.boot-service.mtk_recovery" \
    "$platform_root/system/bin/hw/android.hardware.boot-service.mediatek_recovery"; do
    if [ -f "$service" ]; then
        boot_control_found=1
        echo "using stock AIDL BootControl service: ${service#"$platform_root"}"
    fi
done
if [ "$boot_control_found" -eq 0 ]; then
    echo "warning: stock platform fragment has no known AIDL BootControl binary" >&2
    echo "warning: fastbootd slot switching may be unavailable in this build" >&2
fi
if ! grep -rqF '<fqname>IBootControl/default</fqname>' \
        "$platform_root/vendor/etc/vintf/manifest" 2>/dev/null; then
    echo "warning: no relocated IBootControl/default VINTF fragment was found" >&2
fi

rm -rf "$platform_root/res"
rm -f \
    "$platform_root/miui.factoryreset.rc" \
    "$platform_root/system/bin/adbd" \
    "$platform_root/system/bin/fastbootd" \
    "$platform_root/system/bin/logcat" \
    "$platform_root/system/bin/logd" \
    "$platform_root/system/bin/recovery" \
    "$platform_root/system/bin/servicemanager" \
    "$platform_root/system/bin/sh" \
    "$platform_root/system/bin/toolbox" \
    "$platform_root/system/bin/toybox" \
    "$platform_root/system/bin/update_engine_sideload" \
    "$platform_root/system/bin/hw/android.hardware.health-service.example_recovery" \
    "$platform_root/system/etc/init/android.hardware.health-service.example_recovery.rc" \
    "$platform_root/system/etc/init/recovery-persist.rc" \
    "$platform_root/system/etc/init/recovery-refresh.rc" \
    "$platform_root/system/etc/init/servicemanager.recovery.rc" \
    "$platform_root/system/etc/recovery.fstab" \
    "$platform_root/system/etc/security/otacerts.zip" \
    "$platform_root/system/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$platform_root/vendor/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$platform_root/system/lib64/librecovery_ui.so"

# Drop the stock BootControl rc files; init.recovery.bootctl.rc starts both
# possible service names and exports the compatibility preload.
find "$platform_root/system/etc/init" -maxdepth 1 -type f \
    -name '*boot-service*recovery*.rc' -delete 2>/dev/null || true

if find "$platform_root/system/etc/vintf/manifest" -maxdepth 1 -type f \
        -exec grep -l 'type="device"' {} + 2>/dev/null | grep -q .; then
    echo "pruned platform still contains a device VINTF fragment under /system" >&2
    exit 1
fi

for health_manifest in \
    "$platform_root/system/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$platform_root/vendor/etc/vintf/manifest/android.hardware.health-service.example.xml"; do
    if [ -e "$health_manifest" ]; then
        echo "pruned platform still declares the unavailable AIDL Health service" >&2
        exit 1
    fi
done

for essential in \
    system/bin/init \
    system/bin/linker64 \
    system/lib64/libc.so \
    first_stage_ramdisk/fstab.mt6899 \
    lib/modules/modules.load; do
    if [ ! -f "$platform_root/$essential" ]; then
        echo "pruned platform is missing normal-boot file: $essential" >&2
        exit 1
    fi
done

verify_platform_modules() {
    local root="$1" module

    # These modules are required to bring up the panel, internal UFS and USB
    # gadget in recovery. They are provided only by the stock platform
    # fragment; the kernel repository has no vendor_ramdisk modules.
    for module in \
        panel-o12a-36-02-0a-dsc-vdo.ko \
        mediatek-drm.ko \
        mtk_panel_ext.ko \
        xhci-mtk-hcd-v2.ko \
        mtu3.ko \
        extcon-mtk-usb.ko \
        charger_class.ko \
        tcpc_mt6375.ko \
        ufs-mediatek-mod.ko \
        spi-mt65xx.ko \
        i2c-mt65xx.ko \
        mtk_tinysys_ipi.ko \
        mtk_rpmsg_mbox.ko \
        mtk-mbox.ko; do
        if [ ! -f "$root/lib/modules/$module" ]; then
            echo "stock platform ramdisk is missing required module: $module" >&2
            exit 1
        fi
    done

    if [ -f "$root/lib/modules/extcon-mtk-usb.ko" ] && \
       ! strings -a "$root/lib/modules/extcon-mtk-usb.ko" | grep -qx 'vbus_switch'; then
        echo "stock extcon-mtk-usb lacks the vbus_switch control" >&2
        exit 1
    fi
}

verify_platform_modules "$platform_root"

platform_module_count="$(find "$platform_root/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)"
if [ "$platform_module_count" -lt 150 ]; then
    echo "pruned platform contains only $platform_module_count modules; expected at least 150" >&2
    exit 1
fi

pack_ramdisk() {
    local root="$1" cpio="$2" lz4="$3"

    "$MKBOOTFS" -d "${PRODUCT_OUT}/system" "$root" > "$cpio"
    "$LZ4" -l -12 --favor-decSpeed -f "$cpio" "$lz4" >/dev/null
}

check_combined_ramdisk_size() {
    local label="$1" platform_lz4="$2" recovery_lz4="$3" total

    total=$(( $(stat -c %s "$platform_lz4") + $(stat -c %s "$recovery_lz4") ))
    if [ "$total" -ge 100000000 ]; then
        echo "${label} combined vendor ramdisk is $total bytes; expected less than 100000000" >&2
        exit 1
    fi
    printf '%s\n' "$total"
}

strip_first_stage_avb_flags() {
    local root="$1" fstab_file sanitized_file fstab_count=0

    while IFS= read -r -d '' fstab_file; do
        fstab_count=$((fstab_count + 1))
        sanitized_file="${fstab_file}.disable-avb"
        awk '
            /^[[:space:]]*#/ || NF < 5 { print; next }
            {
                count = split($5, options, ",")
                rebuilt = ""
                for (i = 1; i <= count; i++) {
                    option = options[i]
                    if (option == "avb" || option ~ /^avb=/ || option ~ /^avb_keys=/) {
                        continue
                    }
                    rebuilt = rebuilt == "" ? option : rebuilt "," option
                }
                $5 = rebuilt == "" ? "defaults" : rebuilt
                print
            }
        ' "$fstab_file" > "$sanitized_file"
        mv -f "$sanitized_file" "$fstab_file"
    done < <(find "$root/first_stage_ramdisk" -maxdepth 1 -type f -name 'fstab.*' -print0)

    if [ "$fstab_count" -eq 0 ]; then
        echo "no first-stage fstab files found below $root" >&2
        exit 1
    fi
}

assert_no_first_stage_avb_flags() {
    local root="$1" fstab_file fstab_count=0

    while IFS= read -r -d '' fstab_file; do
        fstab_count=$((fstab_count + 1))
        if ! awk '
            /^[[:space:]]*#/ || NF < 5 { next }
            {
                count = split($5, options, ",")
                for (i = 1; i <= count; i++) {
                    option = options[i]
                    if (option == "avb" || option ~ /^avb=/ || option ~ /^avb_keys=/) {
                        bad = 1
                    }
                }
            }
            END { exit bad ? 1 : 0 }
        ' "$fstab_file"; then
            echo "first-stage AVB flag remains in $fstab_file" >&2
            exit 1
        fi
    done < <(find "$root/first_stage_ramdisk" -maxdepth 1 -type f -name 'fstab.*' -print0)

    if [ "$fstab_count" -eq 0 ]; then
        echo "no first-stage fstab files found below $root" >&2
        exit 1
    fi
}

pack_ramdisk "$platform_root" "$platform_pruned_cpio" "$platform_pruned_lz4"

# Keep the standard image byte-for-byte independent of this override. The
# alternate image removes only fs_mgr AVB options from the stock type-1
# platform first-stage fstab. This is the fragment used for normal Android
# boot; all block paths and other mount flags stay unchanged.
mkdir -p "$disable_avb_platform_root"
cp -a "$platform_root/." "$disable_avb_platform_root/"
strip_first_stage_avb_flags "$disable_avb_platform_root"
assert_no_first_stage_avb_flags "$disable_avb_platform_root"
pack_ramdisk "$disable_avb_platform_root" "$disable_avb_platform_cpio" "$disable_avb_platform_lz4"

total_ramdisk_size="$(check_combined_ramdisk_size standard "$platform_pruned_lz4" "$RECOVERY_LZ4")"
disable_avb_total_ramdisk_size="$(check_combined_ramdisk_size disable-avb "$disable_avb_platform_lz4" "$RECOVERY_LZ4")"

# Additional stock fragments (extra platform or DLKM fragments) are preserved
# so the bootloader keeps the exact module sets it shipped with.
declare -a stock_fragment_args=()
fragment_count="$(read_json_value 'ramdisk_table.__len__' 2>/dev/null || true)"
if [ -n "${fragment_count:-}" ]; then
    index=0
    while [ "$index" -lt "$fragment_count" ]; do
        if [ "$index" -eq "$PLATFORM_INDEX" ]; then
            index=$((index + 1))
            continue
        fi
        entry_file="$(read_json_value "ramdisk_table.${index}.file")"
        entry_type="$(read_json_value "ramdisk_table.${index}.type_name")"
        entry_name="$(read_json_value "ramdisk_table.${index}.name")"
        entry_size="$(read_json_value "ramdisk_table.${index}.size")"
        if [ "$entry_type" = "recovery" ]; then
            index=$((index + 1))
            continue
        fi
        if [ "$entry_size" -eq 0 ] || [ ! -f "${PREBUILT_DIR}/${entry_file}" ]; then
            index=$((index + 1))
            continue
        fi
        stock_fragment_args+=(
            --ramdisk_type "$entry_type"
            --ramdisk_name "${entry_name:-fragment${index}}"
            --vendor_ramdisk_fragment "${PREBUILT_DIR}/${entry_file}"
        )
        index=$((index + 1))
    done
fi

build_vendor_boot() {
    local image="$1" bootconfig="$2" platform_lz4="$3" recovery_lz4="$4"
    local -a mkbootimg_args=(
        --dtb "$patched_dtb"
        --base 0x3fff8000
        --pagesize 4096
        --board "$BOARD_NAME"
        --vendor_cmdline "$VENDOR_CMDLINE"
        --header_version 4
        --kernel_offset 0x00008000
        --ramdisk_offset 0x26f08000
        --tags_offset 0x07c88000
        --dtb_offset 0x07c88000
        --vendor_ramdisk "$platform_lz4"
    )

    mkbootimg_args+=("${stock_fragment_args[@]}")
    mkbootimg_args+=(
        --ramdisk_type recovery
        --ramdisk_name recovery
        --vendor_ramdisk_fragment "$recovery_lz4"
    )

    if [ -n "$bootconfig" ]; then
        mkbootimg_args+=(--vendor_bootconfig "$bootconfig")
    fi
    mkbootimg_args+=(--vendor_boot "$image")
    "$MKBOOTIMG" "${mkbootimg_args[@]}"
    "$AVBTOOL" add_hash_footer \
        --image "$image" \
        --partition_size 117440512 \
        --partition_name vendor_boot \
        --prop "com.android.build.vendor_boot.fingerprint:${fingerprint}"
}

# Parse the finished images again instead of trusting the mkbootimg arguments.
# This catches a wrong fragment type, a missing DTB or an accidental
# recovery-only image before anything is published.
verify_vendor_boot_image() {
    local image="$1" label="$2" inspect_dir="$3"
    local expected_platform_size="$4" expected_recovery_size="$5"

    python3 "$UNPACK_BOOTIMG" --input "$image" --out "$inspect_dir" >/dev/null
    python3 - "$inspect_dir/header.json" "$label" \
        "$expected_platform_size" "$expected_recovery_size" <<'PY'
import json
import sys

header, label = sys.argv[1], sys.argv[2]
expected_platform = int(sys.argv[3])
expected_recovery = int(sys.argv[4])
with open(header, encoding="utf-8") as handle:
    info = json.load(handle)
if info.get("header_version") != 4:
    raise SystemExit(f"{label}: vendor_boot header is not v4")
if info.get("page_size") != 4096:
    raise SystemExit(f"{label}: vendor_boot page size is not 4096")
entries = info.get("ramdisk_table") or []
platforms = [e for e in entries
             if e.get("type_name") == "platform" and e.get("size", 0) > 0]
recoveries = [e for e in entries
              if e.get("type_name") == "recovery" and e.get("size", 0) > 0]
if not platforms:
    raise SystemExit(f"{label}: repacked vendor_boot has no platform fragment")
if platforms[0]["size"] != expected_platform:
    raise SystemExit(f"{label}: platform fragment is {platforms[0]['size']} bytes, "
                     f"expected {expected_platform}")
if len(recoveries) != 1:
    raise SystemExit(f"{label}: expected exactly one recovery fragment, "
                     f"found {len(recoveries)}")
if recoveries[0]["size"] != expected_recovery:
    raise SystemExit(f"{label}: recovery fragment is {recoveries[0]['size']} bytes, "
                     f"expected {expected_recovery}")
if info.get("dtb_size", 0) <= 0:
    raise SystemExit(f"{label}: repacked vendor_boot has no DTB")
if not info.get("vendor_cmdline"):
    raise SystemExit(f"{label}: repacked vendor_boot has an empty vendor cmdline")
print(f"{label}: v4 image ok (platform {platforms[0]['size']} bytes, "
      f"recovery {recoveries[0]['size']} bytes, dtb {info['dtb_size']} bytes)")
PY
}

fingerprint="$(cat "${PRODUCT_OUT}/build_fingerprint.txt" 2>/dev/null || true)"
if [ -z "$fingerprint" ]; then
    fingerprint="Xiaomi/goya_eea/goya:16/BP2A.250605.031.A3/OS3.0.304.0.WOEEUXM:user/release-keys"
fi

STOCK_BOOTCONFIG="${PREBUILT_DIR}/bootconfig"
if [ -s "$STOCK_BOOTCONFIG" ]; then
    build_vendor_boot "$unsigned_image" "$STOCK_BOOTCONFIG" "$platform_pruned_lz4" "$RECOVERY_LZ4"
else
    build_vendor_boot "$unsigned_image" "" "$platform_pruned_lz4" "$RECOVERY_LZ4"
fi

# LK was replaced to permit fastboot flashing on affected devices, but Android
# still receives LK's locked-state boot properties. A bootconfig assignment
# with := takes precedence over the same property supplied earlier in boot.
cat > "$disable_avb_bootconfig" <<'EOF'
androidboot.vbmeta.device_state := "unlocked"
androidboot.verifiedbootstate := "orange"
androidboot.flash.locked := "0"
EOF
build_vendor_boot "$disable_avb_unsigned_image" "$disable_avb_bootconfig" \
    "$disable_avb_platform_lz4" "$RECOVERY_LZ4"

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
mv -f "$unsigned_image" "$OUTPUT_IMAGE"
sha256sum "$OUTPUT_IMAGE" > "${OUTPUT_IMAGE}.sha256"
mv -f "$disable_avb_unsigned_image" "$DISABLE_AVB_OUTPUT_IMAGE"
sha256sum "$DISABLE_AVB_OUTPUT_IMAGE" > "${DISABLE_AVB_OUTPUT_IMAGE}.sha256"

verify_vendor_boot_image "$OUTPUT_IMAGE" standard "$standard_inspect_dir" \
    "$(stat -c %s "$platform_pruned_lz4")" "$(stat -c %s "$RECOVERY_LZ4")"
verify_vendor_boot_image "$DISABLE_AVB_OUTPUT_IMAGE" disable-avb "$disable_avb_inspect_dir" \
    "$(stat -c %s "$disable_avb_platform_lz4")" "$(stat -c %s "$RECOVERY_LZ4")"

if [ -s "$STOCK_BOOTCONFIG" ] && \
        ! cmp -s "$STOCK_BOOTCONFIG" "$standard_inspect_dir/bootconfig"; then
    echo "standard image does not carry the stock vendor bootconfig" >&2
    exit 1
fi
for property in \
    'androidboot.vbmeta.device_state := "unlocked"' \
    'androidboot.verifiedbootstate := "orange"' \
    'androidboot.flash.locked := "0"'; do
    if ! grep -qxF "$property" "$disable_avb_inspect_dir/bootconfig"; then
        echo "disable-avb bootconfig is missing: $property" >&2
        exit 1
    fi
done

test "$(stat -c %s "$DISABLE_AVB_OUTPUT_IMAGE")" = 117440512
cp -fp "$DISABLE_AVB_OUTPUT_IMAGE" "$disable_avb_verify_image"
"$AVBTOOL" verify_image --image "$disable_avb_verify_image"

# OrangeFox creates these names before this post-build step. Replace both
# whole-image outputs so an ordinary vendorbootimage build cannot leave a
# recovery-only image that breaks Android boot.
cp -fp "$OUTPUT_IMAGE" "${PRODUCT_OUT}/vendor_boot.img"
cp -fp "$OUTPUT_IMAGE" "${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya.img"
md5sum "${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya.img" \
    > "${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya.img.md5"
rm -f \
    "${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya.zip" \
    "${PRODUCT_OUT}/OrangeFox-R14.1-Unofficial-goya.zip.md5"

printf 'system-compatible vendor_boot: %s\n' "$OUTPUT_IMAGE"
printf 'disable-avb vendor_boot: %s\n' "$DISABLE_AVB_OUTPUT_IMAGE"
printf 'pruned stock platform fragment: %s bytes (LZ4, %s stock modules)\n' \
    "$(stat -c %s "$platform_pruned_lz4")" "$platform_module_count"
printf 'recovery fragment: %s bytes (LZ4, %s modules)\n' \
    "$(stat -c %s "$RECOVERY_LZ4")" "$module_count"
printf 'combined vendor ramdisk: %s bytes\n' "$total_ramdisk_size"
printf 'disable-avb combined vendor ramdisk: %s bytes\n' "$disable_avb_total_ramdisk_size"
cat "${OUTPUT_IMAGE}.sha256"
