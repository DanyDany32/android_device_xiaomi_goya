#!/usr/bin/env bash
#
# Import a goya phone dump produced by tools/dump-stock-goya.sh.
#
# Usage:
#   tools/import-dump.sh goya-dump.tar [--platform-only]
#
# The dump is expected to contain:
#   vendor_boot.img
#   files/vendor_dlkm/lib/modules/{xiaomi_touch_goya,nt38771_touch_goya,si_haptic,scp}.ko
#   files/odm/...     touchfeature HAL, libraries, firmware and config
#   files/vendor/...  MiTEE KeyMint/Gatekeeper/Weaver, tee-supplicant, KeyMint
#                     libraries, TEE libraries and TA files
#
# The importer updates prebuilt/, proprietary/ and regenerates:
#   proprietary/blobs.mk
#   manifests/device-blobs.sha256
#
# prebuilt/vendor_boot_stock.img is kept for local use but is ignored by Git.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PREPARER="${DEVICE_DIR}/tools/prepare-stock-vendor-boot.sh"
GENERATOR="${DEVICE_DIR}/tools/generate-blobs-mk.sh"
PYTHON="${PYTHON:-python3}"
PLATFORM_ONLY=0

usage() {
    cat <<'EOF'
Usage: tools/import-dump.sh <dump.tar|dump-dir> [--platform-only]

  --platform-only   Only import vendor_boot (platform fragment/DTB). Do not
                    require the four recovery-only vendor_dlkm modules.
EOF
}

INPUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --platform-only)
            PLATFORM_ONLY=1
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$INPUT" ]; then
                echo "ERROR: only one dump may be specified" >&2
                exit 2
            fi
            INPUT="$1"
            ;;
    esac
    shift
done

[ -n "$INPUT" ] || {
    usage >&2
    exit 2
}
[ -e "$INPUT" ] || {
    echo "ERROR: dump not found: $INPUT" >&2
    exit 1
}
for command_name in install find sha256sum sort xargs; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required host command not found: $command_name" >&2
        exit 1
    }
done
[ -x "$PREPARER" ] || {
    echo "ERROR: missing executable preparer: $PREPARER" >&2
    exit 1
}
[ -x "$GENERATOR" ] || {
    echo "ERROR: missing executable blob generator: $GENERATOR" >&2
    exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/goya-dump-import.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

if [ -d "$INPUT" ]; then
    if [ -f "$INPUT/vendor_boot.img" ]; then
        root="$INPUT"
    elif [ -f "$INPUT/goya-dump/vendor_boot.img" ]; then
        root="$INPUT/goya-dump"
    else
        found="$(find "$INPUT" -maxdepth 4 -type f -name vendor_boot.img -print -quit)"
        [ -n "$found" ] || {
            echo "ERROR: dump directory does not contain vendor_boot.img: $INPUT" >&2
            exit 1
        }
        root="$(dirname -- "$found")"
    fi
else
    case "$INPUT" in
        *.tar.gz|*.tgz)
            tar -xzf "$INPUT" -C "$work_dir"
            ;;
        *.tar)
            tar -xf "$INPUT" -C "$work_dir"
            ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || {
                echo "ERROR: unzip is required for a zip dump" >&2
                exit 1
            }
            unzip -q "$INPUT" -d "$work_dir"
            ;;
        *)
            echo "ERROR: unsupported dump format: $INPUT (expected .tar, .tar.gz or .zip)" >&2
            exit 1
            ;;
    esac
    if [ -f "$work_dir/vendor_boot.img" ]; then
        root="$work_dir"
    elif [ -f "$work_dir/goya-dump/vendor_boot.img" ]; then
        root="$work_dir/goya-dump"
    else
        found="$(find "$work_dir" -maxdepth 4 -type f -name vendor_boot.img -print -quit)"
        [ -n "$found" ] || {
            echo "ERROR: dump does not contain vendor_boot.img" >&2
            exit 1
        }
        root="$(dirname -- "$found")"
    fi
fi

[ -f "$root/vendor_boot.img" ] || {
    echo "ERROR: dump root has no vendor_boot.img: $root" >&2
    exit 1
}

module_src=""
for candidate in \
    "$root/files/vendor_dlkm/lib/modules" \
    "$root/files/vendor/lib/modules" \
    "$root/files/lib/modules"; do
    if [ -d "$candidate" ]; then
        module_src="$candidate"
        break
    fi
done

required_modules="xiaomi_touch_goya.ko nt38771_touch_goya.ko si_haptic.ko scp.ko"
missing_modules=""
if [ -n "$module_src" ]; then
    for module in $required_modules; do
        if [ ! -f "$module_src/$module" ]; then
            missing_modules="${missing_modules} ${module}"
        fi
    done
elif [ "$PLATFORM_ONLY" -ne 1 ]; then
    echo "ERROR: dump has no vendor_dlkm module directory; use --platform-only to import only vendor_boot" >&2
    exit 1
fi

if [ "$PLATFORM_ONLY" -ne 1 ] && [ -n "$missing_modules" ]; then
    echo "ERROR: dump is missing required recovery modules:${missing_modules}" >&2
    exit 1
fi

echo "Importing vendor_boot from ${root}/vendor_boot.img"
install -m 0644 "$root/vendor_boot.img" "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img"
"$PREPARER" "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img"

if [ -n "$module_src" ]; then
    rm -rf "${DEVICE_DIR}/prebuilt/modules"
    install -d "${DEVICE_DIR}/prebuilt/modules"
    for module in $required_modules; do
        install -m 0644 "$module_src/$module" "${DEVICE_DIR}/prebuilt/modules/$module"
    done
    echo "Imported recovery modules from ${module_src}"
fi

# Keep the generated proprietary tree deterministic. Only re-import the
# directories owned by this script; never wipe unrelated user files.
rm -rf "${DEVICE_DIR}/proprietary/odm" "${DEVICE_DIR}/proprietary/vendor"
install -d "${DEVICE_DIR}/proprietary"

copy_optional() {
    local src="$1" dest="$2" mode="$3"
    if [ -f "$src" ]; then
        install -d "$(dirname -- "$dest")"
        install -m "$mode" "$src" "$dest"
    fi
}

copy_glob_optional() {
    local pattern="$1" dest_dir="$2" mode="$3" src
    install -d "$dest_dir"
    for src in $pattern; do
        [ -f "$src" ] || continue
        install -m "$mode" "$src" "$dest_dir/$(basename -- "$src")"
    done
}

touch_src="$root/files/odm"
touch_service="$touch_src/bin/hw/vendor.xiaomi.hw.touchfeature-service"
if [ -f "$touch_service" ]; then
    install -d "${DEVICE_DIR}/proprietary/odm/bin/hw"
    install -m 0755 "$touch_service" \
        "${DEVICE_DIR}/proprietary/odm/bin/hw/vendor.xiaomi.hw.touchfeature-service-recovery"
fi

for library in \
    libtouchreport.so \
    libtouchreport_alg.so \
    libtouchreport_hal.so \
    libtouchreport_sensor.so \
    libtensorflowlite_touch_c.so; do
    copy_optional "$touch_src/lib64/$library" \
        "${DEVICE_DIR}/proprietary/odm/lib64/$library" 0644
done

copy_glob_optional "$touch_src/firmware/novatek_nt38771_o12a_fw_*.bin" \
    "${DEVICE_DIR}/proprietary/odm/firmware" 0644
copy_glob_optional "$touch_src/firmware/novatek_nt38771_o12a_mp_*.bin" \
    "${DEVICE_DIR}/proprietary/odm/firmware" 0644
copy_glob_optional "$touch_src/firmware/o12a_nova_*_thp_config.ini" \
    "${DEVICE_DIR}/proprietary/odm/firmware" 0644
copy_optional "$touch_src/firmware/smooth.tflite" \
    "${DEVICE_DIR}/proprietary/odm/firmware/smooth.tflite" 0644
copy_optional "$touch_src/firmware/water_check.tflite" \
    "${DEVICE_DIR}/proprietary/odm/firmware/water_check.tflite" 0644
copy_glob_optional "$touch_src/etc/touch/*.json" \
    "${DEVICE_DIR}/proprietary/odm/etc/touch" 0644
copy_optional "$touch_src/etc/vintf/manifest/vendor.xiaomi.hw.touchfeature-service.xml" \
    "${DEVICE_DIR}/proprietary/odm/etc/vintf/manifest/vendor.xiaomi.hw.touchfeature-service.xml" 0644

vendor_src="$root/files/vendor"
copy_optional "$vendor_src/bin/tee-supplicant" \
    "${DEVICE_DIR}/proprietary/vendor/bin/tee-supplicant" 0755
copy_optional "$vendor_src/bin/hw/android.hardware.security.keymint@3.0-service.mitee" \
    "${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.security.keymint@3.0-service.mitee" 0755
copy_optional "$vendor_src/bin/hw/android.hardware.gatekeeper-service.mitee" \
    "${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.gatekeeper-service.mitee" 0755
copy_optional "$vendor_src/bin/hw/android.hardware.weaver-service.nxp" \
    "${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.weaver-service.nxp" 0755

for manifest in \
    android.hardware.gatekeeper-service.mitee.xml \
    android.hardware.security.keymint-service.mitee.xml \
    android.hardware.security.secureclock-service.mitee.xml \
    android.hardware.security.sharedsecret-service.mitee.xml \
    android.hardware.weaver-service.nxp.xml; do
    copy_optional "$vendor_src/etc/vintf/manifest/$manifest" \
        "${DEVICE_DIR}/proprietary/vendor/etc/vintf/manifest/$manifest" 0644
done

# KeyMint, TEE, Gatekeeper, Weaver and touchfeature dependency closure. Keep
# the original SONAMEs: the stock binaries were built against these exact
# filenames. Importing only the obvious *keymint*/*tee* names is not enough:
# the HALs also need the vendor NDK stubs, libkeymaster*, libcppcose*, the NXP
# Weaver stack and the touch NDK/support libraries, otherwise they fail with
# "library not found" when init starts them.
#
# Platform libraries (libc, libm, libdl, libbinder_ndk, liblog, libsync,
# libvndksupport) stay out of the list: recovery provides its own. libc++.so
# is the exception: the stock Android 16 vendor binaries are BIND_NOW and
# reference std::__libcpp_verbose_abort, which OrangeFox's recovery libc++
# does not export. Ship the stock vendor libc++ in the recovery fragment,
# exactly as the validated R6 image did.
vendor_library_patterns=(
    'android.frameworks.sensorservice-*.so'
    'android.hardware.common-*.so'
    'android.hardware.common.fmq-*.so'
    'android.hardware.gatekeeper-*.so'
    'android.hardware.graphics.*.so'
    'android.hardware.secure_element-*.so'
    'android.hardware.security.*.so'
    'android.hardware.sensors-*.so'
    'android.hardware.weaver-*.so'
    'android.se.omapi-*.so'
    'android.system.suspend-*.so'
    'ese_weaver*.so'
    'lib_android_keymaster*.so'
    'libbase.so'
    'libc++.so'
    'libcppbor*.so'
    'libcppcose*.so'
    'libcrypto.so'
    'libcutils.so'
    'libgatekeeper*.so'
    'libgralloctypes.so'
    'libhardware.so'
    'libhardware_legacy.so'
    'libhidlbase.so'
    'libjc_keymint_transport.nxp.so'
    'libjsoncpp.so'
    'libkeymaster*.so'
    'libkeymint*.so'
    'libmisight.so'
    'libpuresoftkeymasterdevice.so'
    'libsoft_attestation*.so'
    'libteecli.so'
    'libtrusty.so'
    'libui.so'
    'libutils.so'
    'vendor.xiaomi.hw.touchfeature-*.so'
)
if [ -d "$vendor_src/lib64" ]; then
    for pattern in "${vendor_library_patterns[@]}"; do
        copy_glob_optional "$vendor_src/lib64/$pattern" \
            "${DEVICE_DIR}/proprietary/vendor/lib64" 0644
    done
fi
copy_glob_optional "$touch_src/lib64/vendor.xiaomi.hardware.framecapturemanager-*.so" \
    "${DEVICE_DIR}/proprietary/odm/lib64" 0644

copy_glob_optional "$vendor_src/mitee/ta/*.ta" \
    "${DEVICE_DIR}/proprietary/vendor/mitee/ta" 0644
# Stage 2 needs only the AndroidKeymaster and Gatekeeper TAs. Weaver uses the
# NXP eSE service and recovery never starts the face/touch TAs. Keeping the
# unused containers out of the device tree also keeps the recovery fragment
# inside the 64,000,000-byte vendor ramdisk limit.
for ta in "${DEVICE_DIR}/proprietary/vendor/mitee/ta/"*.ta; do
    [ -f "$ta" ] || continue
    case "$(basename -- "$ta")" in
        dba51a17-0563-11e7-93b16fa7b0071a51.ta|4d573443-6a56-4272-ac6f2425af9ef9bb.ta)
            ;;
        *)
            rm -f "$ta"
            ;;
    esac
done
rm -rf "${DEVICE_DIR}/proprietary/odm/mitee/ta"
copy_glob_optional "$vendor_src/firmware/aw8697_*.bin" \
    "${DEVICE_DIR}/proprietary/vendor/firmware" 0644

if [ -f "$root/meta/build-info.txt" ]; then
    install -m 0644 "$root/meta/build-info.txt" "${DEVICE_DIR}/prebuilt/firmware-info.txt"
fi
if [ -f "$root/meta/dump-info.txt" ]; then
    install -m 0644 "$root/meta/dump-info.txt" "${DEVICE_DIR}/prebuilt/dump-info.txt"
fi

"$GENERATOR"

mkdir -p "${DEVICE_DIR}/manifests"
hash_dirs=()
for directory in prebuilt/vendor-boot prebuilt/dtb prebuilt/health prebuilt/modules proprietary; do
    if [ -d "${DEVICE_DIR}/${directory}" ]; then
        hash_dirs+=("$directory")
    fi
done
if [ "${#hash_dirs[@]}" -gt 0 ]; then
    (
        cd "$DEVICE_DIR"
        find "${hash_dirs[@]}" -type f -print0 | sort -z | xargs -0 sha256sum \
            > manifests/device-blobs.sha256
    )
fi

missing_optional=0
if [ -f "$root/meta/missing.txt" ]; then
    missing_optional="$(wc -l < "$root/meta/missing.txt" | tr -d ' ')"
fi

cat <<EOF

Import complete.
  vendor_boot platform : prebuilt/vendor-boot/
  DTB                  : prebuilt/dtb/mt6899-goya.dtb
  modules              : prebuilt/modules/
  proprietary blobs    : proprietary/
  Make fragment        : proprietary/blobs.mk
  blob manifest        : manifests/device-blobs.sha256
  optional blobs absent: ${missing_optional}

Next:
  tools/verify-build-inputs.sh
  git status --short
EOF
