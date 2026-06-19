# Scarica in automatico il kernel e i moduli pre-compilati
if [ ! -d "device/xiaomi/goya-kernel" ]; then
    git clone https://github.com/xiaomi-goya-devs/android_device_xiaomi_goya-kernel device/xiaomi/goya-kernel
fi