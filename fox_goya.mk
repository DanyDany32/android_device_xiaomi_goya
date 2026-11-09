#
# OrangeFox configuration for Xiaomi 15T (goya)
#

OF_MAINTAINER := goya
FOX_TARGET_DEVICES := goya

OF_USE_MAGISKBOOT := 1
OF_USE_NEW_MAGISKBOOT := 1
OF_USE_LZ4_COMPRESSION := 1
OF_USE_SYSTEM_FINGERPRINT := 1

# Goya is a virtual A/B device. OrangeFox 14.1 treats virtual A/B as a
# vanilla configuration; all-block OTA updates are not compatible with it.
OF_SUPPORT_ALL_BLOCK_OTA_UPDATES := 0
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_MANUAL_ROOT_VENDOR_ERROR_FIX := 1
OF_ENABLE_LPTOOLS := 1
OF_USE_TWRP_SAR_DETECT := 1
OF_FLASHLIGHT_ENABLE := 0

# The panel is 1280x2772. OrangeFox lays out the stock 1080-wide theme in a
# 1080x2340 coordinate space so horizontal and vertical scaling stay equal.
OF_SCREEN_H := 2340
OF_SKIP_MULTIUSER_FOLDERS_BACKUP := 1

# Italian first, but keep the language selector usable before /data is
# decrypted. OF_LOAD_DEFAULT_LANGUAGE_BEFORE_DECRYPT avoids an English flash
# on the first decrypt page.
TW_DEFAULT_LANGUAGE := it_IT
OF_LOAD_DEFAULT_LANGUAGE_BEFORE_DECRYPT := 1

# AIDL BootControl is provided by the stock MediaTek service retained from the
# platform ramdisk fragment. See recovery/root/init.recovery.bootctl.rc.
OF_USE_AIDL_BOOT_CONTROL := 1

# The release is flashed as a raw vendor_boot image, so the OrangeFox install
# ZIP never runs and cannot copy Magisk.zip to /sdcard/Fox/FoxFiles. Point the
# addon at /FFiles/OF_Magisk instead; the early-boot helper extracts the APK
# from the vendor_boot partition tail (see tools/magisk-addon.env).
FOX_MOVE_MAGISK_INSTALLER_TO_RAMDISK := 1
