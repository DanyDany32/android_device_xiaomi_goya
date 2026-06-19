echo "Scaricando il Kernel e i Moduli proprietari..."
mkdir -p device/xiaomi/goya-kernel
wget -O kernel.zip "https://github.com/DanyDany32/android_device_xiaomi_goya/releases/download/v1.0/goya_kernel.zip"
unzip -o kernel.zip -d device/xiaomi/goya-kernel/
rm kernel.zip
