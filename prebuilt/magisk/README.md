# Magisk installer APK

`Magisk-v30.7.apk` is the unmodified official Magisk release APK:

- Upstream: https://github.com/topjohnwu/Magisk/releases/tag/v30.7
- SHA-256: `e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5`
- License: GPL-3.0 (see the upstream repository)

The goya vendor ramdisk is limited to 64,000,000 bytes and the current recovery
fragment already uses 63,666,927 bytes, so the APK is not packed into the
ramdisk. `tools/build-system-compatible-vendor-boot.sh` stores it at
`MAGISK_ADDON_OFFSET` (80,003,072, page aligned) in the unused tail of the
112 MiB `vendor_boot` partition. The early-boot helper
`recovery/root/system/bin/magisk-addon-setup.sh` copies it to
`/FFiles/OF_Magisk/Magisk.zip`, which is the path used by the OrangeFox
Magisk addon when `FOX_MOVE_MAGISK_INSTALLER_TO_RAMDISK` is enabled.

To update Magisk:

1. replace this APK with the new official release;
2. update `MAGISK_ADDON_APK_NAME` and `MAGISK_ADDON_SHA256` in
   `tools/magisk-addon.env` (and the version shown by the addon in
   `fox_callback.sh`, if desired);
3. run `tools/verify-build-inputs.sh` and rebuild.
