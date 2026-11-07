#!/usr/bin/env bash
#
# Ensure the build host has enough swap for the low-memory OrangeFox build.
# The GitHub-hosted image usually ships with a small swap; this script tops it
# up only by the missing amount.
#
# Usage:
#   MIN_SWAP_GIB=12 .github/scripts/setup-swap.sh
#
set -euo pipefail

MIN_SWAP_GIB="${MIN_SWAP_GIB:-12}"
SWAP_FILE="${SWAP_FILE:-/swapfile-goya-build}"

if ! [[ "$MIN_SWAP_GIB" =~ ^[0-9]+$ ]] || [ "$MIN_SWAP_GIB" -lt 1 ]; then
    echo "ERROR: MIN_SWAP_GIB must be a positive integer: $MIN_SWAP_GIB" >&2
    exit 1
fi

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

current_swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
target_kib=$((MIN_SWAP_GIB * 1024 * 1024))

if [ "$current_swap_kib" -ge "$target_kib" ]; then
    echo "swap already sufficient: $((current_swap_kib / 1024 / 1024)) GiB" \
         "(target ${MIN_SWAP_GIB} GiB)"
    exit 0
fi

needed_kib=$((target_kib - current_swap_kib))
# Round to MiB and keep a small headroom so swapon does not reject the file
# because of an off-by-one in the reported SwapTotal.
needed_mib=$(((needed_kib + 1023) / 1024 + 256))

available_mib="$(df -Pm "$(dirname -- "$SWAP_FILE")" | awk 'NR == 2 { print $4 }')"
if [ -n "$available_mib" ] && [ "$available_mib" -lt "$needed_mib" ]; then
    echo "ERROR: not enough disk for ${needed_mib} MiB of swap; ${available_mib} MiB free" >&2
    exit 1
fi

if [ -e "$SWAP_FILE" ]; then
    as_root swapoff "$SWAP_FILE" 2>/dev/null || true
    as_root rm -f "$SWAP_FILE"
fi

echo "Adding ${needed_mib} MiB of swap at ${SWAP_FILE}"
if ! as_root fallocate -l "${needed_mib}M" "$SWAP_FILE" 2>/dev/null; then
    as_root dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$needed_mib" status=none
fi
as_root chmod 600 "$SWAP_FILE"
as_root mkswap "$SWAP_FILE" >/dev/null
as_root swapon "$SWAP_FILE"

new_swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
echo "swap total: $((new_swap_kib / 1024 / 1024)) GiB"
free -h
