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
                xiaomi_touch_goya.ko|nt38771_touch_goya.ko|si_haptic.ko)
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
# stock platform fragment (vendor_ramdisk00), with the recovery fragment as a
# fallback for other layouts. The recovery-only touch/haptic/SCP modules are
# intentionally not listed: load-touch-modules.sh loads them during early-boot
# after checking that the SPI controller is present.
stock_recovery_modules="$device_dir/prebuilt/vendor-boot/modules.load.recovery"
if [ -s "$stock_recovery_modules" ]; then
    mkdir -p "$ramdisk/lib/modules"
    cp -fp "$stock_recovery_modules" \
        "$ramdisk/lib/modules/modules.load.recovery"
fi

# The pinned OrangeFox revision's generated init.rc has no MTP gadget. R6 used
# a local template with the MTP function and the two-function (MTP+ADB)
# configfs layout. Replace only the known generated revision; if OrangeFox is
# updated the build stops here instead of silently losing MTP again.
init_rc="$ramdisk/system/etc/init/hw/init.rc"
init_rc_mtp="$device_dir/recovery/init.rc.mtp"
if [ -f "$init_rc" ] && ! grep -qF -- 'functions/ffs.mtp' "$init_rc"; then
    if [ ! -f "$init_rc_mtp" ]; then
        echo "ERROR: MTP init.rc template is missing: $init_rc_mtp" >&2
        exit 1
    fi
    init_rc_sha="$(sha256sum "$init_rc" | awk '{print $1}')"
    if [ "$init_rc_sha" != "f8c0918ab6bb4ffe54cab82ab238b59d9a6f9036da4f5437efe0630c12cf6722" ]; then
        echo "ERROR: unsupported OrangeFox init.rc revision: $init_rc_sha" >&2
        echo "       update recovery/init.rc.mtp before building" >&2
        exit 1
    fi
    echo "-- Restoring the MTP gadget in the recovery init.rc"
    cp -fp "$init_rc_mtp" "$init_rc"
fi

# fastbootd waits for android.hardware.health.IHealth/default before it opens
# /dev/usb-ffs/fastboot. The stock rc declares the service with class hal and
# the hal_health_default SELinux domain, neither of which exists in this
# recovery, so it never starts. device.mk installs the compact stock recovery
# binary as system/bin/android.hardware.health-service.example_recovery and
# init.recovery.mt6899.rc starts it as health-aidl with the recovery domain.
# Drop the stock rc, the redundant system/bin/hw copy and any stale manifest:
# the manifest makes servicemanager wait for a service that starts too late,
# and the build repacker rejects a recovery fragment that still contains it.
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

# Keep the ZIP stack (zip + ziptool with unzip/zipinfo symlinks): recovery
# backups and ZIP installation need it. Drop the large optional GNU/magisk
# tools; toybox already provides tar and sed, and the 64,000,000-byte vendor
# ramdisk leaves no room for the rest. Remove both the target and its /sbin
# symlink so the UI never sees a dangling command.
rm -f \
    "$ramdisk/system/bin/gnutar" \
    "$ramdisk/system/bin/gnused" \
    "$ramdisk/system/bin/magiskboot" \
    "$ramdisk/sbin/gnutar" \
    "$ramdisk/sbin/gnused" \
    "$ramdisk/sbin/magiskboot"
if [ ! -f "$ramdisk/system/bin/ziptool" ]; then
    rm -f "$ramdisk/system/bin/unzip" "$ramdisk/system/bin/zipinfo"
fi
# The Info-ZIP binary may be staged as a regular file in /sbin and moved to
# /system/bin by the relocation loop below. Only drop a dangling sbin symlink.
if [ ! -f "$ramdisk/system/bin/zip" ] && [ ! -f "$ramdisk/sbin/zip" ]; then
    rm -f "$ramdisk/sbin/zip"
fi

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
#
# Compression must never fail the build: the stock InfoZip ziptool binary, for
# example, is rejected by the old OrangeFox UPX with "checksum error". Pack a
# throwaway copy, verify it, and only then replace the original. Binaries that
# UPX cannot pack stay untouched and the ramdisk remains bootable.
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
        # Do not turn symlinks or hardlinks into extra copies of the target.
        if [ -L "$binary" ] || [ "$(stat -c %h "$binary")" -gt 1 ]; then
            continue
        fi
        chmod 0755 "$binary"

        # A previous pass or the vendor blob may already be UPX-packed.
        if "$upx_bin" -q -l "$binary" >/dev/null 2>&1; then
            echo "-- UPX: $name is already packed"
            continue
        fi

        packed="$binary.upx-tmp"
        rm -f "$packed"
        cp -fp "$binary" "$packed"
        if "$upx_bin" -q --lzma "$packed" >/dev/null 2>&1 &&
                "$upx_bin" -q -t "$packed" >/dev/null 2>&1; then
            mv -f "$packed" "$binary"
        else
            rm -f "$packed"
            echo "warning: UPX cannot pack $name; leaving it uncompressed" >&2
        fi
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
    android.hardware.health-service.example_recovery \
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
