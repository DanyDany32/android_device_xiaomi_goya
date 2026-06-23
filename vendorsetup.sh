# ===============================================
# DOWNLOAD KERNEL PRECOMPILATO (Attivo)
# ===============================================
echo "Scaricando il Kernel e i Moduli proprietari..."
mkdir -p device/xiaomi/goya-kernel
wget -O kernel.zip "https://github.com/DanyDany32/android_device_xiaomi_goya/releases/download/v1.0/goya_kernel.zip"
unzip -o kernel.zip -d device/xiaomi/goya-kernel/
rm kernel.zip

# IL FIX DEL DTB: Spostiamo il file in una cartella e aggiungiamo l'estensione .dtb!
mkdir -p device/xiaomi/goya-kernel/dtb_dir
mv device/xiaomi/goya-kernel/dtb device/xiaomi/goya-kernel/dtb_dir/goya.dtb

# Copia i driver del touch estratti dal telefono nella cartella dei moduli
cp device/xiaomi/goya/prebuilt_modules/*.ko device/xiaomi/goya-kernel/modules/

# ===============================================
# SORGENTI KERNEL UFFICIALI (Disattivato)
# ===============================================
# echo "Clonando il codice sorgente ufficiale del Kernel Xiaomi (goya)..."
# git clone --depth=1 -b bsp-goya-v-oss https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git kernel/xiaomi/goya

export OF_SKIP_FBE_DECRYPTION=1
export OF_DONT_PATCH_ENCRYPTED_DEVICE=1
export OF_SKIP_DECRYPTED_DATA=1
export OF_IGNORE_LOGICAL_MOUNT_ERRORS=1
export OF_NO_SPLASH_STAY=1
export OF_NO_RELOAD_AFTER_DECRYPTION=1
export OF_MAINTAIN_MISSING_FSTAB_PARTITIONS=1

# === FIX GRAFICO E SCHERMO ===
export OF_DISABLE_BOOT_ANIMATION=1
export OF_SCREEN_H=2712
export OF_STATUS_H=120
export OF_STATUS_INDENT_LEFT=48
export OF_STATUS_INDENT_RIGHT=48
export OF_DISABLE_MIUI_OTA_BY_DEFAULT=1

# (Commentato per non forzare l'ordine e far decidere al kernel)
# export OF_EXTRA_KERNEL_MODULES="xiaomi_touch_goya.ko nt38771_touch_goya.ko"
