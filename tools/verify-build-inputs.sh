#!/usr/bin/env bash
#
# Preflight checks for the goya OrangeFox device tree.
#
# Usage:
#   tools/verify-build-inputs.sh [--require-blobs]
#
# The check is intentionally usable before a phone dump: missing touch/KeyMint
# blobs only produce warnings unless --require-blobs is given. The stock
# vendor_boot platform fragment is always mandatory because the repacker cannot
# produce a bootable image without it.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REQUIRE_BLOBS=0
PYTHON="${PYTHON:-python3}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-blobs)
            REQUIRE_BLOBS=1
            ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

failures=0
fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}
warn() {
    echo "WARNING: $*" >&2
}
check_file() {
    [ -f "$1" ] || fail "missing file: $1"
}
check_contains() {
    local file="$1" marker="$2" label="$3"
    if [ ! -f "$file" ]; then
        fail "missing file: $file"
        return
    fi
    grep -qF -- "$marker" "$file" || fail "${label}: ${file} does not contain '${marker}'"
}
check_absent() {
    local file="$1" marker="$2" label="$3"
    if [ -f "$file" ] && grep -qF -- "$marker" "$file"; then
        fail "${label}: ${file} still contains '${marker}'"
    fi
}
check_sha256() {
    local file="$1" expected="$2"
    check_file "$file"
    [ -f "$file" ] || return
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || fail "unexpected SHA-256 for $file: $actual"
}
search_tree() {
    local marker="$1" directory="$2"
    grep -RqsF -- "$marker" "$directory"
}

# Missing Stage 2 files are fatal for a release build and warnings otherwise.
require_stage2_file() {
    if [ -f "$1" ]; then
        return 0
    fi
    if [ "$REQUIRE_BLOBS" -eq 1 ]; then
        fail "$2"
    else
        warn "$2"
    fi
}

for command_name in awk cpio find grep od python3 sed sha256sum sort stat strings tar; do
    command -v "$command_name" >/dev/null 2>&1 || \
        fail "required host command not found: ${command_name}"
done
"$PYTHON" -c 'import sys; sys.exit(0)' >/dev/null 2>&1 || \
    fail "Python interpreter not found: ${PYTHON}"

for relative in \
    BoardConfig.mk \
    device.mk \
    omni_goya.mk \
    twrp_goya.mk \
    fox_goya.mk \
    AndroidProducts.mk \
    Android.bp \
    vendorsetup.sh \
    build-lowmem.sh \
    fox_callback.sh \
    .gitignore \
    prebuilt/README.md \
    prebuilt/dtb/mt6899-goya.dtb \
    prebuilt/vendor-boot/header.json \
    prebuilt/vendor-boot/bootconfig \
    patches/orangefox-build-make.patch \
    manifests/orangefox-fox_14.1-pinned.xml \
    tools/apply-orangefox-patches.sh \
    tools/build-system-compatible-vendor-boot.sh \
    tools/dump-stock-goya.sh \
    tools/generate-blobs-mk.sh \
    tools/import-dump.sh \
    tools/patch-vendor-boot-dtb.py \
    tools/prepare-stock-vendor-boot.sh \
    tools/unpack-vendor-boot.py \
    recovery/root/init.recovery.bootctl.rc \
    recovery/root/init.recovery.keymint.rc \
    recovery/root/init.recovery.mt6899.rc \
    recovery/root/init.recovery.project.rc \
    recovery/root/init.recovery.usb.rc \
    recovery/root/system/etc/recovery.fstab \
    recovery/root/system/etc/twrp.flags \
    recovery/root/system/bin/load-touch-modules.sh \
    recovery/root/system/bin/wait-touch-service.sh \
    recovery/root/system/bin/load-haptics-module.sh \
    recovery/root/first_stage_ramdisk/fstab.mt6899 \
    create_pl_dev/Android.bp \
    create_pl_dev/create_pl_dev.cpp \
    create_pl_dev/create_pl_dev.rc \
    libcxx_compat/libcxx_compat.cpp; do
    check_file "${DEVICE_DIR}/${relative}"
done

for script in \
    "${DEVICE_DIR}/build-lowmem.sh" \
    "${DEVICE_DIR}/fox_callback.sh" \
    "${DEVICE_DIR}/tools/apply-orangefox-patches.sh" \
    "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" \
    "${DEVICE_DIR}/tools/dump-stock-goya.sh" \
    "${DEVICE_DIR}/tools/generate-blobs-mk.sh" \
    "${DEVICE_DIR}/tools/import-dump.sh" \
    "${DEVICE_DIR}/tools/prepare-stock-vendor-boot.sh" \
    "${DEVICE_DIR}/tools/verify-build-inputs.sh"; do
    if [ -f "$script" ]; then
        bash -n "$script" || fail "shell syntax check failed: $script"
        [ -x "$script" ] || warn "script is not executable (fix with chmod +x): $script"
    fi
done

for python_file in \
    "${DEVICE_DIR}/tools/unpack-vendor-boot.py" \
    "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py"; do
    if [ -f "$python_file" ]; then
        "$PYTHON" -c \
            'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")' \
            "$python_file" || fail "Python syntax check failed: $python_file"
    fi
done

# Board / image layout
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_BOOT_HEADER_VERSION := 4" "vendor_boot header v4 missing"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_VENDOR_BOOT_HEADER_VERSION := 4" "vendor_boot v4 missing"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_KERNEL_PAGESIZE := 4096" "page size is not 4096"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 117440512" "vendor_boot partition size is wrong"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "TARGET_NO_RECOVERY := true" "goya must not build a recovery partition"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_USES_METADATA_PARTITION := true" "metadata partition support is disabled"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true" "recovery fragment is not in vendor_boot"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "BOARD_RECOVERY_IMAGE_PREPARE" "recovery callback is not wired"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "TW_INCLUDE_CRYPTO := true" "FBE support is disabled"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "TW_INCLUDE_FBE_METADATA_DECRYPT := true" "metadata decrypt support is disabled"
check_contains "${DEVICE_DIR}/BoardConfig.mk" "TW_NO_USB_STORAGE := true" "internal UFS would be exposed as USB storage"
check_absent "${DEVICE_DIR}/BoardConfig.mk" "TW_NO_SCREEN_BLANK" "recovery must keep the standard DRM screen-blank state machine"
check_contains "${DEVICE_DIR}/fox_goya.mk" "OF_USE_AIDL_BOOT_CONTROL := 1" "AIDL BootControl is not selected"
check_contains "${DEVICE_DIR}/fox_goya.mk" "TW_DEFAULT_LANGUAGE := it_IT" "Italian default language is missing"
check_contains "${DEVICE_DIR}/fox_goya.mk" "OF_SCREEN_H := 2340" "screen height override is missing"

# Product / device configuration
check_contains "${DEVICE_DIR}/device.mk" "PRODUCT_SHIPPING_API_LEVEL := 34" "OrangeFox 14.1 must ship API 34"
check_contains "${DEVICE_DIR}/device.mk" "create_pl_dev.recovery" "create_pl_dev recovery variant is missing"
check_contains "${DEVICE_DIR}/device.mk" "libgoya_libcxx_compat" "libc++ compatibility shim is not packaged"
check_contains "${DEVICE_DIR}/device.mk" "-include \$(DEVICE_PATH)/proprietary/blobs.mk" "generated blob rules are not included"
check_contains "${DEVICE_DIR}/AndroidProducts.mk" "twrp_goya-ap2a-eng" "lunch target is missing"
check_contains "${DEVICE_DIR}/Android.bp" 'name: "libgoya_libcxx_compat"' "compat library module is missing"
check_contains "${DEVICE_DIR}/libcxx_compat/libcxx_compat.cpp" '_ZNSt3__122__libcpp_verbose_abortEPKcz' "libc++ abort symbol is missing"
check_contains "${DEVICE_DIR}/create_pl_dev/create_pl_dev.rc" "112b0000.ufshci" "UFS platform path is missing"
check_contains "${DEVICE_DIR}/vendorsetup.sh" "FOX_BUILD_DEVICE=goya" "FOX_BUILD_DEVICE is not goya"
check_absent "${DEVICE_DIR}/vendorsetup.sh" "OF_FORCE_PREBUILT_KERNEL=1" "no prebuilt kernel exists for goya"

# Recovery init / fstab
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.bootctl.rc" "android.hardware.boot-service.mtk_recovery" "mtk BootControl service is missing"
check_absent "${DEVICE_DIR}/recovery/root/init.recovery.bootctl.rc" "android.hardware.boot-service.mediatek_recovery" "a second BootControl service would redefine the AIDL interface"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.bootctl.rc" "libgoya_libcxx_compat.so" "BootControl shim preload is missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" "import /init.recovery.bootctl.rc" "BootControl rc is not imported"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" "start vendor.boot-mtk" "BootControl service is not started"
check_absent "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" "start vendor.boot-mediatek" "only the vendor.boot-mtk service exists"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" "import /init.recovery.keymint.rc" "KeyMint rc is not imported"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.mt6899.rc" "vendor.xiaomi.hw.touchfeature-service-recovery" "touchfeature service is missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" "android.hardware.security.keymint@3.0-service.mitee" "KeyMint service is missing"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" "interface aidl android.hardware.security.keymint.IKeyMintDevice/default" "KeyMint AIDL instance is not declared"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" "interface aidl android.hardware.gatekeeper.IGatekeeper/default" "Gatekeeper AIDL instance is not declared"
check_contains "${DEVICE_DIR}/recovery/root/init.recovery.keymint.rc" "mount none /mnt/vendor/persist /persist bind" "persist bind alias is missing"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab" "fileencryption=:aes-256-hctr2:inlinecrypt_optimized" "userdata hctr2 encryption is missing"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab" "keydirectory=/metadata/vold/metadata_encryption" "metadata key directory is missing"
check_contains "${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab" "sysfs_path=/sys/devices/platform/soc/112b0000.ufshci" "UFS sysfs path is missing"
check_contains "${DEVICE_DIR}/recovery/root/first_stage_ramdisk/fstab.mt6899" "112b0000.ufshci" "first-stage UFS path is missing"
check_absent "${DEVICE_DIR}/recovery/root/system/etc/twrp.flags" "usb-otg" "naive USB OTG entry would treat internal UFS as OTG"
check_absent "${DEVICE_DIR}/recovery/root/system/etc/twrp.flags" "external_sd" "external SD entry is not valid on goya"
if [ -e "${DEVICE_DIR}/recovery/root/vendor/etc/vintf/manifest/android.hardware.health-service.example.xml" ]; then
    fail "recovery declares an unavailable AIDL Health service"
fi

# Repacker / tool expectations
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "117440512" "repacker partition size is wrong"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "--dtb_offset 0x07c88000" "repacker DTB offset is wrong"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "--ramdisk_type recovery" "repacker does not add the recovery fragment"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "verify_platform_modules" "repacker does not validate stock platform modules"
check_contains "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "mediatek,usb-offload" "repacker does not patch the USB offload DTB property"
check_contains "${DEVICE_DIR}/tools/patch-vendor-boot-dtb.py" "mediatek,usb-offload" "DTB patcher does not target the USB offload property"
check_contains "${DEVICE_DIR}/tools/unpack-vendor-boot.py" "VENDOR_HEADER_V4_SIZE" "vendor_boot v4 parser is missing"
check_contains "${DEVICE_DIR}/fox_callback.sh" "vendor.xiaomi.hw.touchfeature-service-recovery" "touchfeature service is not in the UPX list"
check_contains "${DEVICE_DIR}/fox_callback.sh" "xiaomi_touch_goya.ko|nt38771_touch_goya.ko|si_haptic.ko|scp.ko" "recovery module pruning list is missing"
check_contains "${DEVICE_DIR}/build-lowmem.sh" "vendorbootimage" "low-memory build does not target vendor_boot"
check_contains "${DEVICE_DIR}/build-lowmem.sh" "twrp_goya-ap2a-eng" "low-memory build lunch target is wrong"

check_sha256 "${DEVICE_DIR}/patches/orangefox-build-make.patch" "0f1e0679fc4ab9a65d38a0d79d65f47704cd4f96240e1717d7791da209303b2e"
check_sha256 "${DEVICE_DIR}/manifests/orangefox-fox_14.1-pinned.xml" "7262c93f87eaecaa11e6cfde06a7be22b4bb81697d94e74c8c01500ab90a3f60"

# Stock vendor_boot inputs
if [ -f "${DEVICE_DIR}/prebuilt/vendor-boot/header.json" ]; then
    "$PYTHON" - "$DEVICE_DIR" <<'PY'
import json
import os
import sys

device_dir = sys.argv[1]
root = os.path.join(device_dir, "prebuilt", "vendor-boot")
with open(os.path.join(root, "header.json"), encoding="utf-8") as handle:
    info = json.load(handle)
if info.get("header_version") != 4:
    raise SystemExit("prebuilt vendor_boot header is not v4")
if info.get("page_size") != 4096:
    raise SystemExit("prebuilt vendor_boot page size is not 4096")
entries = info.get("ramdisk_table") or []
platforms = [entry for entry in entries if entry.get("type_name") == "platform" and entry.get("size", 0) > 0]
if not platforms:
    raise SystemExit("prebuilt vendor_boot has no platform fragment")
for entry in entries:
    # The stock recovery fragment is replaced by the OrangeFox build and is
    # intentionally not committed: only the platform/DLKM inputs are reused.
    if entry.get("type_name") == "recovery":
        continue
    fragment = os.path.join(root, entry["file"])
    if not os.path.isfile(fragment):
        raise SystemExit(f"missing prebuilt fragment: {fragment}")
    if os.path.getsize(fragment) != entry["size"]:
        raise SystemExit(f"prebuilt fragment size mismatch: {fragment}")
dtb = os.path.join(root, "dtb")
with open(dtb, "rb") as handle:
    head = handle.read(0x44)
if head[:4] != b"\xd0\x0d\xfe\xed" and head[0x40:0x44] != b"\xd0\x0d\xfe\xed":
    raise SystemExit("prebuilt vendor_boot DTB is not a valid FDT")
print(f"prebuilt vendor_boot v4 platform fragments: {len(platforms)}, table entries: {len(entries)}")
PY
    platform_file="$("$PYTHON" - "${DEVICE_DIR}/prebuilt/vendor-boot/header.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    info = json.load(handle)
entry = next((item for item in info["ramdisk_table"] if item["type_name"] == "platform" and item["size"] > 0), None)
if entry is None:
    raise SystemExit(1)
print(entry["file"])
PY
)"
    platform_magic="$(od -An -tx1 -N4 "${DEVICE_DIR}/prebuilt/vendor-boot/${platform_file}" | tr -d ' \n')"
    case "$platform_magic" in
        02214c18|04224d18|1f8b*|30373037) ;;
        *) fail "unknown platform fragment compression magic: ${platform_magic}" ;;
    esac

    recovery_module_list="${DEVICE_DIR}/prebuilt/vendor-boot/modules.load.recovery"
    if [ ! -s "$recovery_module_list" ]; then
        warn "prebuilt/vendor-boot/modules.load.recovery is missing; recovery first stage will fall back to the platform modules.load (no MTK IPI/RPMSG mailbox modules)"
    else
        for module in mtk_tinysys_ipi.ko mtk_rpmsg_mbox.ko mtk-mbox.ko; do
            if ! grep -qxF "$module" "$recovery_module_list"; then
                warn "stock recovery module list has no ${module}; scp.ko may fail later"
            fi
        done
    fi
fi
check_file "${DEVICE_DIR}/prebuilt/vendor_boot_stock.sha256"
if [ -f "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img" ]; then
    stock_size="$(stat -c %s "${DEVICE_DIR}/prebuilt/vendor_boot_stock.img")"
    [ "$stock_size" -eq 117440512 ] || warn "prebuilt/vendor_boot_stock.img is ${stock_size} bytes, expected 117440512"
else
    warn "prebuilt/vendor_boot_stock.img is absent; extracted prebuilt/vendor-boot is still usable"
fi

# Kernel modules and optional blobs
module_present=0
module_vermagic=""
for module in xiaomi_touch_goya.ko nt38771_touch_goya.ko si_haptic.ko scp.ko; do
    module_path="${DEVICE_DIR}/prebuilt/modules/${module}"
    if [ -f "$module_path" ]; then
        module_present=$((module_present + 1))
        value="$(strings -a "$module_path" | sed -n 's/^vermagic=//p' | head -n 1 || true)"
        if [ -z "$value" ]; then
            warn "module has no vermagic string: $module"
        elif [ -z "$module_vermagic" ]; then
            module_vermagic="$value"
        elif [ "$value" != "$module_vermagic" ]; then
            fail "module vermagic mismatch: ${module}=${value}, expected ${module_vermagic}"
        fi
    fi
done
if [ "$module_present" -gt 0 ]; then
    for required_module in xiaomi_touch_goya.ko nt38771_touch_goya.ko si_haptic.ko; do
        check_file "${DEVICE_DIR}/prebuilt/modules/${required_module}"
    done
    if [ -n "$module_vermagic" ]; then
        echo "recovery module vermagic: ${module_vermagic}"
    fi
else
    warn "no recovery-only kernel modules found; build will produce a Stage 1 image without touch/haptics"
fi

if [ -f "${DEVICE_DIR}/prebuilt/modules/si_haptic.ko" ]; then
    if ! compgen -G "${DEVICE_DIR}/proprietary/vendor/firmware/aw8697_*.bin" >/dev/null; then
        warn "si_haptic.ko is present but AW8697 firmware is missing"
    fi
fi

touch_service="${DEVICE_DIR}/proprietary/odm/bin/hw/vendor.xiaomi.hw.touchfeature-service-recovery"
if [ -f "$touch_service" ]; then
    for library in libtouchreport.so libtouchreport_hal.so libtouchreport_sensor.so; do
        check_file "${DEVICE_DIR}/proprietary/odm/lib64/${library}"
    done
    if ! compgen -G "${DEVICE_DIR}/proprietary/odm/firmware/novatek_nt38771_o12a_fw_*.bin" >/dev/null; then
        warn "touch HAL is present but Novatek firmware is missing"
    fi
    if [ ! -f "${DEVICE_DIR}/proprietary/odm/etc/vintf/manifest/vendor.xiaomi.hw.touchfeature-service.xml" ]; then
        warn "touchfeature VINTF manifest is missing; the HAL may not be visible to clients"
    fi
    for library in \
        vendor.xiaomi.hw.touchfeature-V1-ndk.so \
        android.frameworks.sensorservice-V1-ndk.so \
        android.hardware.sensors-V2-ndk.so \
        libui.so \
        libmisight.so; do
        require_stage2_file "${DEVICE_DIR}/proprietary/vendor/lib64/${library}" \
            "touch HAL runtime library is missing: ${library}"
    done
    require_stage2_file \
        "${DEVICE_DIR}/proprietary/odm/lib64/vendor.xiaomi.hardware.framecapturemanager-V1-ndk.so" \
        "touch HAL ODM runtime library is missing: vendor.xiaomi.hardware.framecapturemanager-V1-ndk.so"
else
    warn "touchfeature HAL is absent; build will produce a Stage 1 image without touch"
fi

keymint_service="${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.security.keymint@3.0-service.mitee"
gatekeeper_service="${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.gatekeeper-service.mitee"
weaver_service="${DEVICE_DIR}/proprietary/vendor/bin/hw/android.hardware.weaver-service.nxp"
vendor_manifest_dir="${DEVICE_DIR}/proprietary/vendor/etc/vintf/manifest"

# Missing VINTF fragments are fatal for a Stage 2 release: without them
# servicemanager never exposes the HAL to Keystore2 even when the binary and
# the TA files are in the ramdisk.
if [ -f "$keymint_service" ]; then
    check_file "${DEVICE_DIR}/proprietary/vendor/bin/tee-supplicant"
    if ! compgen -G "${DEVICE_DIR}/proprietary/vendor/lib64/libkeymint*.so" >/dev/null; then
        fail "KeyMint is present but no libkeymint*.so was imported"
    fi
    check_file "${DEVICE_DIR}/proprietary/vendor/lib64/libteecli.so"
    if ! compgen -G "${DEVICE_DIR}/proprietary/vendor/mitee/ta/*.ta" >/dev/null; then
        fail "KeyMint is present but vendor/mitee/ta is empty"
    fi
    keymint_manifest="${vendor_manifest_dir}/android.hardware.security.keymint-service.mitee.xml"
    require_stage2_file "$keymint_manifest" \
        "KeyMint VINTF manifest is missing: android.hardware.security.keymint-service.mitee.xml"
    if [ -f "$keymint_manifest" ]; then
        check_contains "$keymint_manifest" "IKeyMintDevice/default" \
            "KeyMint manifest does not declare IKeyMintDevice/default"
        check_contains "$keymint_manifest" "IRemotelyProvisionedComponent/default" \
            "KeyMint manifest does not declare IRemotelyProvisionedComponent/default"
    fi
    # The MiTEE service binary also implements ISecureClock and ISharedSecret.
    # The stock firmware declares them in separate VINTF fragments, so require
    # those too: without them Keystore2 cannot see the interfaces even though
    # the code is present in the same process.
    for manifest in \
        android.hardware.security.secureclock-service.mitee.xml \
        android.hardware.security.sharedsecret-service.mitee.xml; do
        require_stage2_file "${vendor_manifest_dir}/${manifest}" \
            "KeyMint VINTF manifest is missing: ${manifest}"
    done
    # Runtime dependency closure of the KeyMint service. These SONAMEs are
    # direct DT_NEEDED entries of the stock binary, so they must be imported
    # even though their names do not mention keymint.
    for library in \
        android.hardware.security.keymint-V3-ndk.so \
        android.hardware.security.secureclock-V1-ndk.so \
        android.hardware.security.sharedsecret-V1-ndk.so \
        android.hardware.security.rkp-V3-ndk.so \
        libkeymaster_messages.so \
        libkeymaster_portable.so \
        libpuresoftkeymasterdevice.so \
        libcppcose_rkp.so \
        libtrusty.so \
        libjsoncpp.so; do
        require_stage2_file "${DEVICE_DIR}/proprietary/vendor/lib64/${library}" \
            "KeyMint runtime library is missing: ${library}"
    done
    if [ -f "$gatekeeper_service" ]; then
        require_stage2_file \
            "${vendor_manifest_dir}/android.hardware.gatekeeper-service.mitee.xml" \
            "Gatekeeper VINTF manifest is missing"
        for library in \
            android.hardware.gatekeeper-V1-ndk.so \
            libgatekeeper.so; do
            require_stage2_file "${DEVICE_DIR}/proprietary/vendor/lib64/${library}" \
                "Gatekeeper runtime library is missing: ${library}"
        done
    else
        warn "Gatekeeper MiTEE is absent; metadata decryption may fail"
    fi
    if [ -f "$weaver_service" ]; then
        require_stage2_file \
            "${vendor_manifest_dir}/android.hardware.weaver-service.nxp.xml" \
            "Weaver VINTF manifest is missing"
        for library in \
            android.hardware.weaver-V2-ndk.so \
            android.hardware.secure_element-V1-ndk.so \
            android.se.omapi-V1-ndk.so \
            android.system.suspend-V1-ndk.so \
            ese_weaver.nxp.so; do
            require_stage2_file "${DEVICE_DIR}/proprietary/vendor/lib64/${library}" \
                "Weaver runtime library is missing: ${library}"
        done
    else
        warn "NXP Weaver is absent; Gatekeeper-only key derivation will be used"
    fi
else
    warn "KeyMint MiTEE is absent; build will produce a Stage 1 image without FBE decryption"
fi

if [ "$REQUIRE_BLOBS" -eq 1 ]; then
    [ "$module_present" -ge 3 ] || fail "--require-blobs: recovery modules were not imported"
    [ -f "$touch_service" ] || fail "--require-blobs: touchfeature HAL was not imported"
    [ -f "$keymint_service" ] || fail "--require-blobs: KeyMint MiTEE was not imported"
fi

blobs_mk="${DEVICE_DIR}/proprietary/blobs.mk"
if [ -f "$blobs_mk" ]; then
    while IFS= read -r relative; do
        if [ -n "$relative" ]; then
            check_file "${DEVICE_DIR}/${relative}"
        fi
    done < <(sed -n 's#.*\$(DEVICE_PATH)/\([^:[:space:]]*\):.*#\1#p' "$blobs_mk" | sort -u)
    duplicate_destinations="$(sed -n 's#.*\$(DEVICE_PATH)/[^:]*:\([^[:space:]\\]*\).*#\1#p' "$blobs_mk" | sort | uniq -d)"
    if [ -n "$duplicate_destinations" ]; then
        fail "duplicate PRODUCT_COPY_FILES destination(s): $(printf '%s' "$duplicate_destinations" | tr '\n' ' ')"
    fi
else
    warn "proprietary/blobs.mk is absent; run tools/generate-blobs-mk.sh"
fi

if [ -f "${DEVICE_DIR}/manifests/device-blobs.sha256" ]; then
    (
        cd "$DEVICE_DIR"
        sha256sum --check --quiet manifests/device-blobs.sha256
    ) || fail "device blob hashes do not match manifests/device-blobs.sha256"
fi

check_contains "${DEVICE_DIR}/.gitignore" "prebuilt/vendor_boot_stock.img" "stock vendor_boot image is not ignored"
if command -v git >/dev/null 2>&1 && \
        git -C "$DEVICE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$DEVICE_DIR" ls-files --error-unmatch prebuilt/vendor_boot_stock.img >/dev/null 2>&1; then
        fail "prebuilt/vendor_boot_stock.img is tracked by Git; remove it from the index"
    fi
fi

# OrangeFox source tree (optional when the device tree is checked out alone)
TOP_DIR=""
if [ -n "${ORANGEFOX_TOP:-}" ] && [ -f "${ORANGEFOX_TOP}/build/envsetup.sh" ]; then
    TOP_DIR="$ORANGEFOX_TOP"
elif [ -f "${DEVICE_DIR}/../../../build/envsetup.sh" ]; then
    TOP_DIR="$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)"
fi

if [ -n "$TOP_DIR" ]; then
    if ! search_tree "Fox_Before_Recovery_Image" "${TOP_DIR}/build/make"; then
        fail "OrangeFox build/make patch is not applied (missing Fox_Before_Recovery_Image)"
    fi
    # OF_USE_AIDL_BOOT_CONTROL is a bootable/recovery build variable
    # (orangefox.mk -> -DOF_USE_AIDL_BOOT_CONTROL); vendor/twrp does not
    # reference it.
    if ! search_tree "OF_USE_AIDL_BOOT_CONTROL" "${TOP_DIR}/bootable/recovery"; then
        fail "OrangeFox bootable/recovery does not support OF_USE_AIDL_BOOT_CONTROL"
    fi
    check_file "${TOP_DIR}/bootable/recovery/gui/theme/common/languages/it_IT.xml"
    if [ -f "${TOP_DIR}/bootable/recovery/gui/theme/common/languages/it_IT.xml" ]; then
        "$PYTHON" -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' \
            "${TOP_DIR}/bootable/recovery/gui/theme/common/languages/it_IT.xml" || \
            fail "Italian language file is not valid XML"
    fi
    [ -x "${TOP_DIR}/prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-objcopy" ] || \
        warn "expected LLVM objcopy not found; fox_callback will skip .gnu_debugdata pruning"
else
    warn "OrangeFox source tree not found; skipping source-side checks"
fi

if [ "$failures" -gt 0 ]; then
    echo "Preflight failed with ${failures} error(s)" >&2
    exit 1
fi

echo "goya build input verification passed"
echo "Device tree: ${DEVICE_DIR}"
if [ -n "$TOP_DIR" ]; then
    echo "OrangeFox:   ${TOP_DIR}"
fi
