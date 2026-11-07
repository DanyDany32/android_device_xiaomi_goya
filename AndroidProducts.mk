#
# OrangeFox / TWRP product definitions for Xiaomi 15T (goya)
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/omni_goya.mk \
    $(LOCAL_DIR)/twrp_goya.mk

COMMON_LUNCH_CHOICES := \
    twrp_goya-ap2a-eng \
    twrp_goya-eng \
    omni_goya-eng
