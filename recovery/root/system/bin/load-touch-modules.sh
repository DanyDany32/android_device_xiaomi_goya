#!/system/bin/sh

setprop vendor.touch.modules.ready 0

load_module() {
    module="$1"
    name="${module%.ko}"

    if grep -q "^${name} " /proc/modules; then
        echo "$name is already loaded"
        return 0
    fi

    echo "loading $module"
    insmod "/lib/modules/$module" || return 1
}

# Messages from the stock platform fragment normally loaded most of the
# display and SPI stack in first stage. Search by OF compatible first and by
# SPI modalias second; MTK exposes the controller as novatek,NVT-ts-spi.
touch_spi=""
for device in /sys/bus/spi/devices/*; do
    [ -d "$device" ] || continue
    modalias="$(cat "$device/modalias" 2>/dev/null)"
    compatible="$(cat "$device/of_node/compatible" 2>/dev/null)"
    case "$modalias $compatible" in
        *novatek*NVT-ts*|*NVT-ts-spi*|*touch-spi*)
            touch_spi="$device"
            break
            ;;
    esac
done

if [ -z "$touch_spi" ]; then
    echo "touch SPI device is missing; refusing to load touch drivers" >&2
    exit 1
fi
echo "found touch controller at ${touch_spi##*/}"

# scp.ko is optional: the platform fragment already loads its three MTK
# mailbox/IPI dependencies, but not the SCP remoteproc itself.
if [ -f /lib/modules/scp.ko ]; then
    load_module scp.ko || echo "scp.ko did not load; continuing without SCP" >&2
fi

load_module xiaomi_touch_goya.ko || exit 3
load_module nt38771_touch_goya.ko || exit 4

setprop vendor.touch.modules.ready 1
echo "touch modules loaded; inspect dmesg for controller probe status"
