#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

# Eredita configurazioni base AOSP
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)

# Eredita configurazioni comuni TWRP/OrangeFox
$(call inherit-product, vendor/twrp/config/common.mk)

PRODUCT_BRAND := Xiaomi
PRODUCT_DEVICE := goya
PRODUCT_MANUFACTURER := Xiaomi
PRODUCT_MODEL := 25069PTEBG
PRODUCT_NAME := twrp_goya
