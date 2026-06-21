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
export OF_NO_SPLASH_STAY=1
# MODIFICA AGGIUNTA ORA: Evita i bootloop dovuti alla fstab "falsa"
export OF_NO_RELOAD_AFTER_DECRYPTION=1
export OF_MAINTAIN_MISSING_FSTAB_PARTITIONS=1

# === FIX GRAFICO E SCHERMO ===
# Disabilita l'animazione di avvio che fa crashare il DRM su MediaTek
export OF_DISABLE_BOOT_ANIMATION=1

# Diciamo alla recovery le dimensioni esatte per non farla impazzire
export OF_SCREEN_H=2712
export OF_STATUS_H=120
export OF_STATUS_INDENT_LEFT=48
export OF_STATUS_INDENT_RIGHT=48

# Evita loop dovuti a problemi col touch
export OF_DISABLE_MIUI_OTA_BY_DEFAULT=1
