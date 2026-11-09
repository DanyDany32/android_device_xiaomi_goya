# OrangeFox 14.1 per Xiaomi 15T (`goya`)

Device tree OrangeFox 14.1 (base TWRP Android 14) per lo Xiaomi 15T
(`goya`, MediaTek MT6899 / Dimensity 8400-Ultra).

Goya non ha una partizione `recovery`: la recovery è il frammento di tipo
`recovery` dentro `vendor_boot` (header v4). Per questo il risultato finale non
è un `recovery.img`, ma una immagine completa `vendor_boot` da 117440512 byte,
composta da:

1. frammento `platform` stock (display, UFS, USB, firmware e moduli
   `vendor_ramdisk`), opportunamente ripulito;
2. frammento `recovery` OrangeFox;
3. DTB stock, con la sola proprietà `mediatek,usb-offload` rimossa;
4. bootconfig stock;
5. footer AVB ricalcolato.

## Stato

| Fase | Contenuto | Stato |
| --- | --- | --- |
| Stage 1 | boot, display, touch, ADB, MTP, fastbootd, ZIP | input importati dal firmware OS3.0.311.0 |
| Stage 2 | decrypt FBE/Metadata con KeyMint/Gatekeeper/Weaver, TouchReport, MTP e ZIP | blob TEE e dipendenze importati; decrypt FBE, MTP e ZIP validati sul dispositivo (protector secdis) |

Un albero senza i servizi Stage 2 (health-aidl, KeyMint, Gatekeeper) produce
una immagine Stage 1 senza decrypt. Quando questi servizi sono presenti, il
repack richiede la libc++ vendor e si ferma se manca, perché sono BIND_NOW e
referenziano `std::__libcpp_verbose_abort`.
`tools/verify-build-inputs.sh --require-blobs` impone la presenza dei blob per
una release completa.

## Struttura

| Percorso | Contenuto |
| --- | --- |
| `BoardConfig.mk`, `device.mk`, `fox_goya.mk`, `omni_goya.mk` | configurazione build |
| `recovery/root/` | init, fstab, twrp.flags e helper di recovery |
| `prebuilt/` | frammento platform stock, DTB, moduli e checksum |
| `proprietary/` | blob ODM/vendor importati e `blobs.mk` generato |
| `tools/` | dump, import, verifica, repack, patch |
| `patches/` | patch generica OrangeFox `build/make` |
| `manifests/` | manifest OrangeFox 14.1 pinnato |
| `.github/workflows/` | build CI e preparazione input stock |

## Prerequisiti

Host Linux (o GitHub Actions Ubuntu 24.04) per la build OrangeFox:

- 16 GB di RAM e almeno 12 GB di swap;
- spazio disco: misurato su un runner sano da 145 GB, la sync depth-1 porta
  l'uso da 19 GiB a un picco di 99 GiB (circa 80 GiB di dati nuovi, `.repo`
  incluso). Il workflow richiede quindi **115 GiB liberi** su un runner a
  disco singolo, oppure 100 GiB su un `/mnt` separato più 45 GiB per `out/`.
  I runner pubblici 4-core hanno un disco da 150 GB (circa 127 GiB liberi
  dopo il cleanup); se il runner assegnato è più piccolo il workflow si ferma
  prima della sync, e un watchdog interrompe comunque la sync se lo spazio
  scende sotto 8 GiB, così i log vengono salvati;
- runner GitHub **pubblico 4-core**: i runner privati 2-core hanno circa 14 GiB
  liberi e non bastano;
- `git`, `repo`, `python3`, `cpio`, `lz4`, `avbtool`, `mkbootimg`, `java 17`.

Su Windows non è possibile compilare: servono WSL2 con una distro Linux oppure
la CI GitHub.

## 1. Ottenere gli input stock dal telefono

DFRoot (DirtyFrag) è sufficiente: dà accesso root, quindi si possono leggere
direttamente `vendor_boot` e i blob da `/odm` e `/vendor`. Non serve scaricare
un firmware completo, a meno che il dump non sia possibile (per esempio se il
root viene perso o SELinux blocca `dd`).

Collegare il telefono con ADB e root attivo, poi:

```bash
tools/dump-stock-goya.sh goya-dump.tar
```

Lo script legge:

- `vendor_boot` dello slot corrente (112 MiB);
- i quattro moduli `vendor_dlkm`;
- HAL touch, librerie, firmware e config Novatek;
- KeyMint/Gatekeeper/Weaver MiTEE, `tee-supplicant`, librerie TEE e solo i
  due TA necessari (AndroidKeymaster e Gatekeeper; gli altri TA, incluso
  MiFace da ~29 MiB, sono esclusi);
- firmware haptics AW8697.

Viene prodotto anche `meta/build-info.txt` con le proprietà del firmware, utile
per identificare la regione (EEA/Global/CN).

Se il dump da telefono non è possibile, scaricare il firmware ufficiale della
regione corretta, estrarre `vendor_boot.img` e usare il solo import platform:

```bash
tools/prepare-stock-vendor-boot.sh /path/to/vendor_boot.img
```

## 2. Importare e verificare

```bash
tools/import-dump.sh goya-dump.tar
tools/verify-build-inputs.sh
```

L'import aggiorna `prebuilt/`, `proprietary/`, `proprietary/blobs.mk` e
`manifests/device-blobs.sha256`. Per una release completa:

```bash
tools/verify-build-inputs.sh --require-blobs
```

`prebuilt/vendor_boot_stock.img` resta solo in locale ed è ignorato da Git.

## 3. Build

### GitHub Actions (consigliata)

1. Pubblicare questo device tree come repository GitHub.
2. Caricare `goya-dump.tar` come asset di una release (o usare un URL HTTPS
   diretto).
3. Lanciare il workflow **Prepare goya stock inputs** con:
   - `dump_url`: URL del dump;
   - `dump_sha256`: hash opzionale, consigliato;
   - `platform_only`: solo se non si vogliono importare i blob.
4. Il workflow importa gli input, li committa e avvia **Build OrangeFox goya**.
5. Al termine scaricare gli artifact o la prerelease con le due immagini.

La build non parte sui normali `push`: viene avviata dal workflow **Prepare
goya stock inputs** oppure manualmente con `workflow_dispatch`. Così un push
senza input stock non produce una build destinata a fallire e non annulla la
build appena avviata dal workflow di import.

### Build locale

```bash
mkdir -p ~/fox_14.1 && cd ~/fox_14.1
repo init -u https://gitlab.com/OrangeFox/sync.git -b 14.1 --depth=1
# oppure usare il manifest pinnato del device tree:
#   manifests/orangefox-fox_14.1-pinned.xml
repo sync -c -j4 --no-clone-bundle --no-tags
```

Copiare il device tree in `device/xiaomi/goya`, applicare la patch generica e
compilare:

```bash
mkdir -p device/xiaomi/goya
rsync -a --delete /path/to/device_xiaomi_goya/ device/xiaomi/goya/
device/xiaomi/goya/tools/apply-orangefox-patches.sh "$PWD"

export ORANGEFOX_TOP="$PWD"
device/xiaomi/goya/build-lowmem.sh adbd vendorbootimage
```

`build-lowmem.sh` esegue `mka adbd vendorbootimage` e poi il repack completo.
Un `mka vendorbootimage` eseguito a mano produce un layout recovery-only
intermedio: **non va flashato**.

Output in `out/target/product/goya/`:

- `OrangeFox-R14.1-Unofficial-goya-system-compatible.img`
- `OrangeFox-R14.1-Unofficial-goya-disable-avb-system-compatible.img`
- relativi `.sha256`

Entrambe le immagini sono da 117440512 byte e hanno un footer AVB valido.
Il repack rifiuta un ramdisk combinato superiore a 64.000.000 byte.

## 4. Flash

Conservare sempre una copia del `vendor_boot` stock del proprio firmware.
Il nome del blocco dipende dallo slot attivo (`vendor_boot_a` o
`vendor_boot_b`):

```bash
slot="$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"
adb shell "su -c 'dd if=/dev/block/by-name/vendor_boot${slot} of=/sdcard/vendor_boot_stock.img'"
adb pull /sdcard/vendor_boot_stock.img
```

`tools/dump-stock-goya.sh` fa già la stessa cosa e produce anche i blob.

Verificare lo slot corrente e flashare solo quello:

```bash
slot="$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"
adb reboot bootloader
fastboot getvar current-slot
fastboot flash "vendor_boot${slot}" OrangeFox-R14.1-Unofficial-goya-system-compatible.img
fastboot reboot recovery
```

Note:

- il bootloader deve essere sbloccato; il root DFRoot da solo non sblocca
  fastboot;
- non flashare `recovery.img`, `boot.img` o il `vendor_boot` intermedio;
- usare prima l'immagine standard;
- l'immagine `disable-avb` serve solo se Android mostra ancora lo stato
  `locked` o se il first-stage `fs_mgr` rifiuta i logical partition. Non
  sblocca il bootloader e non modifica il vbmeta del dispositivo;
- per tornare indietro: `fastboot flash "vendor_boot${slot}" vendor_boot_stock.img`.

## 5. Decrypt FBE (Stage 2)

Il device tree include già:

- avvio di `android.hardware.security.keymint@3.0-service.mitee`,
  Gatekeeper MiTEE e (se presente) Weaver NXP;
- bind di `/persist` e alias ODM in `init.recovery.mt6899.rc`;
- fstab `userdata` con `aes-256-hctr2` e key directory metadata;
- librerie touch e servizio TouchReport per la UI;
- libc++ vendor stock (`vendor/lib64/libc++.so`) nel frammento recovery: i
  binari Android 16 di KeyMint/Gatekeeper/health sono BIND_NOW e richiedono
  `std::__libcpp_verbose_abort`, che la libc++ di OrangeFox non esporta.

Per completare il decrypt servono solo due TA MiTEE, AndroidKeymaster
(`dba51a17-...`) e Gatekeeper (`4d573443-...`); Weaver usa il servizio NXP eSE,
non un TA. Gli altri TA (incluso MiFace da ~29 MiB) vengono scartati: recovery
non li usa e i container sono quasi incomprimibili. Il ramdisk combinato ha un
limite fisico di 64.000.000 byte: R6 (62.484.458 byte) è bootabile, mentre
64.734.211 byte mandano il bootloader in bootloop. La build si ferma sopra
64.000.000 byte.

Il decrypt FBE è stato validato sul dispositivo. Il firmware stock mantiene,
accanto al protector Weaver, un secondo protector LSKF basato su
Gatekeeper/`.secdis` con lo stesso PIN (stesso salt e parametri scrypt). Il
protector secdis non richiede né l'eSE né lo stack OMAPI, quindi la recovery lo
usa come fallback. La patch `patches/vold-fbe-secdisc-fallback.patch`, applicata
a `system/vold` da `tools/apply-orangefox-patches.sh`, fa scegliere a
`KeystoreInfo::getHandle()` il protector secdis quando quello corrente usa
Weaver e ne esiste uno con gli stessi parametri `.pwd`. Il percorso Weaver
resta invariato per i dispositivi con eSE/OMAPI funzionante.

Verifica eseguita: log `using secdis to decrypt spblob` → `GateKeeper status ok`
→ `User 0 Decrypted Successfully!`, con `/data/data` e `/data/media/0`
accessibili. Se `verify-build-inputs.sh` segnala Weaver assente, il device può
comunque usare il protector secdis; verificare il log `recovery.log` in caso di
errore.

### MTP e ZIP

`fox_callback.sh` sostituisce l'`init.rc` generato dalla revisione OrangeFox
pinnata con `recovery/init.rc.mtp` (protetto da un controllo SHA-256), perché
quel file non dichiara il gadget MTP. Il template aggiunge `ffs.mtp`, il mount
`/dev/usb-ffs/mtp` e la configurazione `mtp,adb` con due funzioni.

La build mantiene lo stack ZIP completo (`system/bin/zip`, `system/bin/ziptool`,
symlink `unzip`/`zipinfo` e `sbin/zip`) e `magiskboot`
(`system/bin/magiskboot` con symlink `sbin/magiskboot`) per l'integrazione
Magisk e la manipolazione delle immagini di boot. Rimuove `gnutar`, `gnused` e
`scp.ko`, che non servono in recovery e occupano spazio prezioso: `tar` e `sed`
restano disponibili via toybox. `magiskboot` costa circa 750 KB compressi e
lascia ~333 KB di margine sotto il limite di 64.000.000 byte del vendor
ramdisk; per questo va verificato il boot sul dispositivo dopo ogni modifica.

### Addon Magisk

L'addon Fox Addons → Magisk non può contare sullo ZIP di installazione
OrangeFox, perché la release si flasha come immagine `vendor_boot` completa.
La build incorpora quindi l'APK ufficiale **Magisk v30.7** (SHA-256
`e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5`) nella coda
non usata della partizione `vendor_boot` (offset `80.003.072`, allineato a
4096 byte), fuori dal ramdisk da 64 MB. All'avvio
`recovery/root/system/bin/magisk-addon-setup.sh` copia l'APK in
`/FFiles/OF_Magisk/Magisk.zip`, cioè il percorso usato dall'addon quando
`FOX_MOVE_MAGISK_INSTALLER_TO_RAMDISK` è attivo. L'APK è coperto dall'hash AVB
e l'immagine resta di 117.440.512 byte; il ramdisk recovery resta a
63.666.927 byte, quindi il margine di boot non cambia.

Per aggiornare Magisk: sostituire `prebuilt/magisk/Magisk-v30.7.apk`,
aggiornare `prebuilt/magisk/README.md` e `tools/magisk-addon.env` (nome, SHA-256
e versione mostrata), quindi ricostruire e ritestare l'addon sul dispositivo.
Non inserire l'APK nel ramdisk: 11,6 MB non entrano nel limite di 64 MB.

Validazione sul dispositivo: MTP espone `/data/media/0`, `zip`, `unzip` e
`zipinfo` funzionano, l'addon Magisk trova `Magisk.zip` e installa Magisk, e il
boot Android successivo arriva a `sys.boot_completed=1`.

## 6. Troubleshooting

| Sintomo | Causa probabile |
| --- | --- |
| Schermo nero dopo il flash | `vendor_boot` recovery-only, frammento platform non unito |
| Touch assente | moduli `xiaomi_touch_goya.ko` / `nt38771_touch_goya.ko` o HAL non importati |
| ADB/MTP assenti | `mtu3.ko`, `xhci-mtk-hcd-v2.ko`, `extcon-mtk-usb.ko` mancanti dal platform fragment |
| Decrypt non parte | KeyMint/TA MiTEE assenti, `/persist` non montato, manifest VINTF sotto `/system` |
| Decrypt fallisce sul protector Weaver | eSE/OMAPI non disponibili in recovery; verificare che esista un protector `.secdis` con lo stesso salt e che la patch vold sia applicata (`findSecdiscFallback` in `KeystoreInfo.cpp`) |
| KeyMint/Gatekeeper/health non partono (`__libcpp_verbose_abort`) | manca `vendor/lib64/libc++.so` nel frammento recovery: verificare la regola in `proprietary/blobs.mk` e l'import in `tools/import-dump.sh` |
| Fastbootd non cambia slot | servizio AIDL BootControl stock assente dal platform fragment |
| Build senza moduli display | `prebuilt/vendor-boot/` non importato |
| Addon Magisk: "Il file non esiste" | `/FFiles/OF_Magisk/Magisk.zip` non creato: verificare `magisk-addon-setup.sh`, l'offset in `tools/magisk-addon.env` e che l'immagine flashata sia quella con l'APK nella coda |

Eseguire sempre il preflight prima della build:

```bash
tools/verify-build-inputs.sh
```

## 7. Note

- La build OrangeFox completa richiede in genere 90-150 minuti a freddo su un
  runner pubblico 4-core; con la ccache calda scende a 20-50 minuti. La ccache
  viene salvata subito dopo una compilazione riuscita, quindi resta disponibile
  anche se la validazione finale fallisce.
- I moduli recovery provengono dal `vendor_dlkm` stock, non dal kernel
  LineageOS: il vermagic deve coincidere con il kernel del firmware.
- La regione del firmware (EEA/Global/CN) deve essere la stessa del telefono.
  Un `vendor_boot` di un'altra regione può avere DTB e moduli incompatibili.
