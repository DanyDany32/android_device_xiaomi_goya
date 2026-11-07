#!/bin/bash
#
# OrangeFox recovery-root callback for Xiaomi 15T (goya).
#
# BoardConfig.mk invokes this through BOARD_RECOVERY_IMAGE_PREPARE. It runs
# after Make has assembled the recovery root and before OrangeFox packs the
# type-2 recovery fragment.
#
set -e

ramdisk="$1"
phase="$2"
device_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
terminfo="$ramdisk/system/etc/terminfo"

if [ "$phase" != "--first-call" ]; then
    exit 0
fi

if [ -z "$ramdisk" ] || [ ! -d "$ramdisk" ]; then
    echo "ERROR: recovery root not found: $ramdisk" >&2
    exit 1
fi

# relink_libraries is a phony Make target and may leave an older library in
# recovery/root after libminuitwrp is rebuilt. Refresh it immediately before
# OrangeFox packs the recovery fragment.
product_out="$(dirname "$(dirname "$ramdisk")")"
minuitwrp_src="$product_out/system/lib64/libminuitwrp.so"
minuitwrp_dst="$ramdisk/system/lib64/libminuitwrp.so"
if [ -f "$minuitwrp_src" ]; then
    echo "-- Refreshing recovery libminuitwrp.so from the current build output"
    cp -fp "$minuitwrp_src" "$minuitwrp_dst"
fi

# The stock platform fragment supplies display, USB, storage and most MTK
# modules. Keep only the recovery-only touch/haptic/SCP modules that are not
# present there. If a Stage 1 build has no imported modules, this is a no-op.
if [ -d "$ramdisk/lib/modules" ]; then
    find "$ramdisk/lib/modules" -maxdepth 1 -type f -name '*.ko' -print0 |
        while IFS= read -r -d '' module; do
            case "$(basename "$module")" in
                xiaomi_touch_goya.ko|nt38771_touch_goya.ko|si_haptic.ko|scp.ko)
                    ;;
                *)
                    rm -f "$module"
                    ;;
            esac
        done

    # The bootloader concatenates the stock platform fragment and this recovery
    # fragment. A modules.load/modules.dep here would override the platform
    # copies and make first-stage init load only the four recovery modules,
    # leaving display, UFS and USB without their drivers. The recovery modules
    # are loaded explicitly by load-touch-modules.sh later in boot.
    rm -f \
        "$ramdisk/lib/modules/modules.load" \
        "$ramdisk/lib/modules/modules.dep"
fi

# Reuse the stock recovery first-stage list (display, UFS, USB and the MTK
# mailbox/IPI trio). It is extracted by prepare-stock-vendor-boot.sh from the
# stock recovery fragment. The recovery-only touch/haptic/SCP modules are
# intentionally not listed: load-touch-modules.sh loads them during early-boot
# after checking that the SPI controller is present.
stock_recovery_modules="$device_dir/prebuilt/vendor-boot/modules.load.recovery"
if [ -s "$stock_recovery_modules" ]; then
    mkdir -p "$ramdisk/lib/modules"
    cp -fp "$stock_recovery_modules" \
        "$ramdisk/lib/modules/modules.load.recovery"
fi

# The stock recovery declares an AIDL Health example service that the
# OrangeFox recovery fragment does not provide. Leaving the manifest in the
# fragment makes servicemanager wait for a service that never starts, which
# blocks fastbootd before USB is ready.
rm -f \
    "$ramdisk/vendor/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$ramdisk/system/etc/vintf/manifest/android.hardware.health-service.example.xml" \
    "$ramdisk/system/bin/hw/android.hardware.health-service.example_recovery" \
    "$ramdisk/system/etc/init/android.hardware.health-service.example_recovery.rc"

# lpdumpd is a diagnostic daemon, not the lptools implementation used for
# dynamic-partition operations. Keep lpunpack/lptools/fastbootd, drop the large
# snapshot/protobuf dependency chain when OrangeFox included it.
rm -f \
    "$ramdisk/system/bin/lpdump" \
    "$ramdisk/system/bin/lpdumpd" \
    "$ramdisk/system/etc/init/lpdumpd.rc" \
    "$ramdisk/system/lib64/liblpdump.so" \
    "$ramdisk/system/lib64/liblpdump_interface-cpp.so" \
    "$ramdisk/system/lib64/libprotobuf-cpp-full.so" \
    "$ramdisk/system/lib64/libsnapshot.so"

# Mini debug sections are already compressed data and are not used on-device.
objcopy_bin="prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-objcopy"
readelf_bin="prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-readelf"
if [ -x "$objcopy_bin" ] && [ -x "$readelf_bin" ]; then
    while IFS= read -r -d '' binary; do
        if file "$binary" | grep -q ELF && \
                "$readelf_bin" -SW "$binary" 2>/dev/null | grep -q '\.gnu_debugdata'; then
            "$objcopy_bin" --remove-section=.gnu_debugdata "$binary"
        fi
    done < <(find "$ramdisk/system" -type f -print0)
else
    echo "warning: LLVM objcopy/readelf not found; skipping .gnu_debugdata pruning" >&2
fi

# UPX is optional on goya. Only compress binaries that exist in this build;
# Stage 1 images may not contain the touchfeature HAL or KeyMint binaries.
upx_bin="vendor/recovery/tools/upx"
if [ -x "$upx_bin" ]; then
    upx_binaries=(
        avbctl awk bc bootctl bu charger create_pl_dev dump_image e2fsck
        e2fsdroid erase_image exfat-fuse fastbootd fatlabel flash_image fsck.exfat
        fsck.f2fs fsck.fat fscryptpolicyget grep keystore2 keystore_cli_v2 logcat
        logd lptools lzma make_f2fs minadbd mke2fs mkexfatfs mkfs.fat nano
        ozip_decrypt pigz reboot recovery resetprop resize2fs sgdisk simg2img
        sload_f2fs tune2fs twrp update_engine_sideload
        vendor.xiaomi.hw.touchfeature-service-recovery vold_prepare_subdirs
        watchdogd ziptool
    )
    for name in "${upx_binaries[@]}"; do
        binary="$ramdisk/system/bin/$name"
        [ -f "$binary" ] || continue
        chmod 0755 "$binary"
        "$upx_bin" -q --lzma "$binary" >/dev/null
        "$upx_bin" -q -t "$binary" >/dev/null
    done
else
    echo "warning: OrangeFox UPX binary not found; skipping compression" >&2
fi

# Modern fs_config assigns unknown /sbin files mode 0644. Place the actual
# terminal tools/helpers under /system/bin (0755) and retain /sbin symlinks.
if [ -d "$ramdisk/sbin" ]; then
    while IFS= read -r -d '' source; do
        name="$(basename "$source")"
        target="$ramdisk/system/bin/$name"
        if [ "$name" = nano ] && [ -f "$target" ]; then
            rm -f "$source"
        else
            rm -f "$target"
            mv "$source" "$target"
        fi
        ln -s "/system/bin/$name" "$source"
    done < <(find "$ramdisk/sbin" -maxdepth 1 -type f -print0)
fi

# Keep English and Italian only. The user-facing default is Italian; English
# remains as the fallback for untranslated strings.
if [ -d "$ramdisk/twres/languages" ]; then
    if [ ! -f "$ramdisk/twres/languages/it_IT.xml" ]; then
        echo "warning: it_IT.xml is missing from the OrangeFox language set" >&2
    fi
    find "$ramdisk/twres/languages" -maxdepth 1 -type f \
        ! -name en.xml \
        ! -name it_IT.xml \
        -delete
fi

if [ -d "$terminfo" ]; then
    keep_dir="$(mktemp -d)"
    trap 'rm -rf "$keep_dir"' EXIT

    for entry in a/ansi l/linux v/vt100 x/xterm x/xterm-256color; do
        if [ -f "$terminfo/$entry" ]; then
            mkdir -p "$keep_dir/$(dirname "$entry")"
            cp -p "$terminfo/$entry" "$keep_dir/$entry"
        fi
    done

    rm -rf "$terminfo"
    mv "$keep_dir" "$terminfo"
    trap - EXIT
fi

# Recovery helper scripts and proprietary binaries must be executable even
# when PRODUCT_COPY_FILES preserved a host-side 0644 mode.
for helper in \
    load-touch-modules.sh \
    wait-touch-service.sh \
    load-haptics-module.sh \
    vendor.xiaomi.hw.touchfeature-service-recovery; do
    if [ -f "$ramdisk/system/bin/$helper" ]; then
        chmod 0755 "$ramdisk/system/bin/$helper"
    fi
done
if [ -f "$ramdisk/vendor/bin/tee-supplicant" ]; then
    chmod 0755 "$ramdisk/vendor/bin/tee-supplicant"
fi
if [ -d "$ramdisk/vendor/bin/hw" ]; then
    find "$ramdisk/vendor/bin/hw" -maxdepth 1 -type f -exec chmod 0755 {} +
fi

# These are build-debug manifests and are not consumed by recovery at runtime.
rm -f "$ramdisk/ramdisk-files.txt" "$ramdisk/ramdisk-files.sha256sum"
