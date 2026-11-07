#
# OrangeFox recovery board configuration for Xiaomi 15T (goya)
# MediaTek MT6899 / Dimensity 8400-Ultra, A/B, virtual A/B, vendor_boot v4.
#

DEVICE_PATH := device/xiaomi/goya

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv9-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a55

# Bootloader / platform
TARGET_BOARD_PLATFORM := mt6899
TARGET_BOOTLOADER_BOARD_NAME := goya
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true
TARGET_USES_UEFI := true

BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
BUILD_BROKEN_DUP_RULES := true

# Goya has no recovery partition. The recovery ramdisk is a RECOVERY fragment
# inside vendor_boot (header v4). The build only produces the fragment; the
# post-build repacker merges it with the stock platform fragment and DTB.
TARGET_NO_RECOVERY := true
TARGET_NO_KERNEL := true
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := true
BOARD_RAMDISK_USE_LZ4 := true

TARGET_KERNEL_ARCH := arm64
TARGET_KERNEL_HEADER_ARCH := arm64

# Header / load addresses (must match the stock MTK vendor_boot header)
BOARD_BOOT_HEADER_VERSION := 4
BOARD_VENDOR_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_BASE := 0x3fff8000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_PAGE_SIZE := 4096
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x26f08000
BOARD_KERNEL_TAGS_OFFSET := 0x07c88000
BOARD_DTB_OFFSET := 0x07c88000

BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2
BOARD_MKBOOTIMG_ARGS += \
    --header_version $(BOARD_BOOT_HEADER_VERSION) \
    --kernel_offset $(BOARD_KERNEL_OFFSET) \
    --ramdisk_offset $(BOARD_RAMDISK_OFFSET) \
    --tags_offset $(BOARD_KERNEL_TAGS_OFFSET) \
    --dtb_offset $(BOARD_DTB_OFFSET)

BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

# Product configuration
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USERIMAGES_USE_EROFS := true
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_METADATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_USES_METADATA_PARTITION := true
BOARD_HAS_LARGE_FILESYSTEM := true

# Partition sizes (bytes)
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 117440512
BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE := 8388608
BOARD_DTBOIMG_PARTITION_SIZE := 8388608
BOARD_PVMFWIMAGE_PARTITION_SIZE := 2097152
BOARD_FLASH_BLOCK_SIZE := 131072

# Super partition layout
BOARD_SUPER_PARTITION_SIZE := 11811160064
BOARD_SUPER_PARTITION_BLOCK_DEVICES := super
BOARD_SUPER_PARTITION_METADATA_DEVICE := super
BOARD_SUPER_PARTITION_GROUPS := xiaomi_dynamic_partitions
BOARD_XIAOMI_DYNAMIC_PARTITIONS_SIZE := $(shell expr $(BOARD_SUPER_PARTITION_SIZE) - 4194304)
BOARD_XIAOMI_DYNAMIC_PARTITIONS_PARTITION_LIST := \
    system \
    product \
    system_ext \
    vendor \
    odm \
    system_dlkm \
    vendor_dlkm \
    odm_dlkm

# A/B / virtual A/B. PRODUCT_USE_DYNAMIC_PARTITIONS and the virtual A/B flags
# are product variables and are set in device.mk: the build system marks every
# PRODUCT_* variable readonly once product configuration is resolved, so they
# cannot be assigned from BoardConfig.mk.
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    init_boot \
    vendor_boot \
    dtbo \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    system \
    system_ext \
    system_dlkm \
    vendor \
    vendor_dlkm \
    product \
    odm \
    odm_dlkm \
    pvmfw

# AVB
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3

# OrangeFox / TWRP
TW_THEME := portrait_hdpi
TARGET_SCREEN_WIDTH := 1280
TARGET_SCREEN_HEIGHT := 2772
TW_MAX_BRIGHTNESS := 2047
TW_DEFAULT_BRIGHTNESS := 1000
TW_USE_LEGACY_BATTERY_SERVICES := true
TW_INCLUDE_FASTBOOTD := true
TW_INCLUDE_LPTOOLS := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_EROFS := true
TW_EXCLUDE_APEX := true
TW_HAS_MTP := true
TW_MTP_DEVICE := /dev/mtp_usb
# USB Storage exposes /data as a block device and is not wanted. OTG host
# storage is not enabled until a goya-specific USB disk resolver exists
# (goya's internal UFS is /dev/block/sda, so a naive sdX rule is unsafe).
TW_NO_USB_STORAGE := true
TW_EXCLUDE_DEFAULT_USB_INIT := true
TW_INPUT_BLACKLIST := "hbtp_vm"
TARGET_USES_LOGD := true
TWRP_INCLUDE_LOGCAT := true
RECOVERY_SDCARD_ON_DATA := true

# FBE / metadata encryption
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
OF_USE_DMCTL := 1
TW_USE_FSCRYPT_POLICY := 2

TW_RECOVERY_ADDITIONAL_RELINK_LIBRARY_FILES = \
    $(TARGET_OUT_SHARED_LIBRARIES)/libtrusty.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libgoya_libcxx_compat.so

# Keep the image lean. The recovery fragment only carries the touch, haptic
# and SCP modules that are absent from the stock platform fragment.
BOARD_RECOVERY_IMAGE_PREPARE = bash $(DEVICE_PATH)/fox_callback.sh $(TARGET_RECOVERY_ROOT_OUT) --first-call

-include $(DEVICE_PATH)/fox_goya.mk
