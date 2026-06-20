echo "Scaricando il Kernel e i Moduli proprietari..."
mkdir -p device/xiaomi/goya-kernel
wget -O kernel.zip "https://github.com/DanyDany32/android_device_xiaomi_goya/releases/download/v1.0/goya_kernel.zip"
unzip -o kernel.zip -d device/xiaomi/goya-kernel/
rm kernel.zip

# IL FIX DEL DTB: Spostiamo il file in una cartella e aggiungiamo l'estensione .dtb!
mkdir -p device/xiaomi/goya-kernel/dtb_dir
mv device/xiaomi/goya-kernel/dtb device/xiaomi/goya-kernel/dtb_dir/goya.dtb

export OF_SKIP_FBE_DECRYPTION=1
export OF_DONT_PATCH_ENCRYPTED_DEVICE=1
export OF_SKIP_DECRYPTED_DATA=1
export OF_IGNORE_LOGICAL_MOUNT_ERRORS=1
