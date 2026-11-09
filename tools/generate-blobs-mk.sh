#!/usr/bin/env bash
#
# Regenerate proprietary/blobs.mk from the files imported by import-dump.sh.
# Only existing files are emitted, so a Stage 1 build without touch/KeyMint
# blobs still works.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MK_FILE="${DEVICE_DIR}/proprietary/blobs.mk"
declare -a copy_entries=()
declare -A destinations=()

add_copy() {
    local relative_source="$1"
    local destination="$2"

    if [ ! -f "${DEVICE_DIR}/${relative_source}" ]; then
        return 0
    fi
    if [ -n "${destinations[$destination]:-}" ]; then
        echo "ERROR: duplicate destination in blobs.mk: ${destination}" >&2
        echo "       sources: ${destinations[$destination]} and ${relative_source}" >&2
        exit 1
    fi
    destinations["$destination"]="$relative_source"
    copy_entries+=("    \$(DEVICE_PATH)/${relative_source}:${destination}")
}

# scp.ko is intentionally not packed: the platform fragment already loads the
# MTK mailbox/IPI dependencies and load-touch-modules.sh treats SCP as
# optional. Dropping it keeps the vendor ramdisk inside the 64,000,000-byte
# bootloader limit.
for module in \
    xiaomi_touch_goya.ko \
    nt38771_touch_goya.ko \
    si_haptic.ko; do
    add_copy "prebuilt/modules/${module}" "recovery/root/lib/modules/${module}"
done

for firmware in "${DEVICE_DIR}/proprietary/vendor/firmware/"aw8697_*.bin; do
    [ -f "$firmware" ] || continue
    add_copy "proprietary/vendor/firmware/$(basename -- "$firmware")" \
        "recovery/root/vendor/firmware/$(basename -- "$firmware")"
done

add_copy "proprietary/odm/bin/hw/vendor.xiaomi.hw.touchfeature-service-recovery" \
    "recovery/root/system/bin/vendor.xiaomi.hw.touchfeature-service-recovery"

for library in "${DEVICE_DIR}/proprietary/odm/lib64/"*.so; do
    [ -f "$library" ] || continue
    add_copy "proprietary/odm/lib64/$(basename -- "$library")" \
        "recovery/root/system/lib64/goya-touch/$(basename -- "$library")"
done

for asset in \
    "${DEVICE_DIR}/proprietary/odm/firmware/"* \
    "${DEVICE_DIR}/proprietary/odm/etc/touch/"*; do
    [ -f "$asset" ] || continue
    add_copy "proprietary/odm/${asset#"${DEVICE_DIR}/proprietary/odm/"}" \
        "recovery/root/system/etc/goya-touch/$(basename -- "$asset")"
done

for manifest in "${DEVICE_DIR}/proprietary/odm/etc/vintf/manifest/"*.xml; do
    [ -f "$manifest" ] || continue
    add_copy "proprietary/odm/etc/vintf/manifest/$(basename -- "$manifest")" \
        "recovery/root/odm/etc/vintf/manifest/$(basename -- "$manifest")"
done

for manifest in "${DEVICE_DIR}/proprietary/vendor/etc/vintf/manifest/"*.xml; do
    [ -f "$manifest" ] || continue
    add_copy "proprietary/vendor/etc/vintf/manifest/$(basename -- "$manifest")" \
        "recovery/root/vendor/etc/vintf/manifest/$(basename -- "$manifest")"
done

# servicemanager reads the merged /vendor/manifest.xml and /system/manifest.xml,
# not only the per-service fragments above. Without them the Stage 2 HALs never
# register and the recovery UI waits forever on keystore2 after the splash.
# These files are recovery configuration, not stock partition blobs, so they
# live under recovery/vintf/ and are copied only when the KeyMint service is
# present (a Stage 1 build keeps its previous behaviour).
if [ -f "${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.security.keymint@3.0-service.mitee" ]; then
    add_copy "recovery/vintf/vendor-manifest.xml" "recovery/root/vendor/manifest.xml"
    add_copy "recovery/vintf/system-manifest.xml" "recovery/root/system/manifest.xml"
fi

add_copy "proprietary/vendor/bin/tee-supplicant" \
    "recovery/root/vendor/bin/tee-supplicant"
for binary in "${DEVICE_DIR}/proprietary/vendor/bin/hw/"*; do
    [ -f "$binary" ] || continue
    add_copy "proprietary/vendor/bin/hw/$(basename -- "$binary")" \
        "recovery/root/vendor/bin/hw/$(basename -- "$binary")"
done

for library in "${DEVICE_DIR}/proprietary/vendor/lib64/"*.so; do
    [ -f "$library" ] || continue
    add_copy "proprietary/vendor/lib64/$(basename -- "$library")" \
        "recovery/root/vendor/lib64/$(basename -- "$library")"
done

# Only two TEE TAs are needed for Stage 2 FBE decryption:
#   dba51a17-...  AndroidKeymaster (KeyMint / secure deletion secret)
#   4d573443-...  Gatekeeper
# Weaver is implemented by the NXP eSE service, not by a TA. The remaining
# vendor/ODM TAs (including the ~29 MiB MiFace TA) are unused by recovery and
# their containers are almost incompressible; packing them pushed the
# vendor ramdisk over the bootloader limit.
is_recovery_ta_required() {
    case "$(basename -- "$1")" in
        dba51a17-0563-11e7-93b16fa7b0071a51.ta|4d573443-6a56-4272-ac6f2425af9ef9bb.ta)
            return 0
            ;;
    esac
    return 1
}

for ta in "${DEVICE_DIR}/proprietary/vendor/mitee/ta/"*.ta; do
    [ -f "$ta" ] || continue
    if ! is_recovery_ta_required "$ta"; then
        continue
    fi
    add_copy "proprietary/vendor/mitee/ta/$(basename -- "$ta")" \
        "recovery/root/vendor/mitee/ta/$(basename -- "$ta")"
done

install -d "${DEVICE_DIR}/proprietary"
tmp_file="${MK_FILE}.tmp.$$"
{
    echo "# Generated by tools/generate-blobs-mk.sh. Do not edit manually."
    echo "#"
    echo "# Only files present under prebuilt/modules and proprietary/ are listed;"
    echo "# a Stage 1 build without imported touch/KeyMint blobs remains valid."
    if [ "${#copy_entries[@]}" -eq 0 ]; then
        echo "# No imported blobs were found."
    else
        echo "PRODUCT_COPY_FILES += \\"
        last_index=$((${#copy_entries[@]} - 1))
        for index in "${!copy_entries[@]}"; do
            if [ "$index" -lt "$last_index" ]; then
                printf '%s \\\n' "${copy_entries[$index]}"
            else
                printf '%s\n' "${copy_entries[$index]}"
            fi
        done
    fi
} > "$tmp_file"
chmod 0644 "$tmp_file"
mv -f "$tmp_file" "$MK_FILE"

echo "Generated ${MK_FILE} with ${#copy_entries[@]} blob copy rule(s)"
