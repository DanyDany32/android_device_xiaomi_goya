#
# OrangeFox recovery product for Xiaomi 15T (goya)
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)
$(call inherit-product, vendor/twrp/config/common.mk)
$(call inherit-product, device/xiaomi/goya/device.mk)

PRODUCT_DEVICE := goya
PRODUCT_NAME := omni_goya
PRODUCT_BRAND := Xiaomi
PRODUCT_MODEL := 25069PTEBG
PRODUCT_MANUFACTURER := Xiaomi
PRODUCT_RELEASE_NAME := Xiaomi 15T

PRODUCT_GMS_CLIENTID_BASE := android-xiaomi

# Firmware baseline: Xiaomi 15T EEA OS3.0.304.0.WOEEUXM (Android 16).
# Keep this in sync with prebuilt/ and proprietary-files.txt.
BUILD_FINGERPRINT := Xiaomi/goya_eea/goya:16/BP2A.250605.031.A3/OS3.0.304.0.WOEEUXM:user/release-keys
PRIVATE_BUILD_DESC := missi-user 16 BP2A.250605.031.A3 OS3.0.304.0.WOEEUXM release-keys

PRODUCT_BUILD_PROP_OVERRIDES += \
    TARGET_DEVICE=goya \
    PRODUCT_NAME=goya \
    PRIVATE_BUILD_DESC="$(PRIVATE_BUILD_DESC)"
