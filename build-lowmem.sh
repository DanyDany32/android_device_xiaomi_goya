#!/usr/bin/env bash
#
# Low-memory OrangeFox build wrapper for Xiaomi 15T (goya).
#
# Usage:
#   build-lowmem.sh                 # adbd + vendorbootimage + repack
#   build-lowmem.sh vendorbootimage
#   build-lowmem.sh recoveryimage   # produces only the recovery fragment, not
#                                   # a flashable whole vendor_boot
#
# A plain `vendorbootimage` build is recovery-only on goya and must never be
# flashed. When the vendorbootimage target is built, this script always runs
# tools/build-system-compatible-vendor-boot.sh to merge the stock platform
# fragment, DTB and AVB footer.
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [ -n "${ORANGEFOX_TOP:-}" ]; then
    TOP_DIR="${ORANGEFOX_TOP}"
elif [ -f "${DEVICE_DIR}/../../../build/envsetup.sh" ]; then
    TOP_DIR="$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)"
else
    TOP_DIR="${HOME}/fox_14.1"
fi

if [ ! -f "${TOP_DIR}/build/envsetup.sh" ]; then
    echo "ERROR: OrangeFox source tree not found: ${TOP_DIR}" >&2
    echo "Set ORANGEFOX_TOP=/path/to/fox_14.1 and retry." >&2
    exit 1
fi

if [ "${TERM_PROGRAM:-}" = "vscode" ]; then
    echo "warning: run this from a normal terminal, not the VS Code integrated terminal." >&2
    echo "warning: systemd-oomd can kill the whole VS Code scope during Soong spikes." >&2
fi

export OF_LOW_MEMORY_BUILD="${OF_LOW_MEMORY_BUILD:-1}"
export OF_BUILD_JOBS="${OF_BUILD_JOBS:-1}"
export ALLOW_MISSING_DEPENDENCIES="${ALLOW_MISSING_DEPENDENCIES:-true}"
export FOX_BUILD_DEVICE="${FOX_BUILD_DEVICE:-goya}"
export FOX_AB_DEVICE="${FOX_AB_DEVICE:-1}"
export FOX_VIRTUAL_AB_DEVICE="${FOX_VIRTUAL_AB_DEVICE:-1}"
export NINJA_ARGS="${NINJA_ARGS:--j${OF_BUILD_JOBS} -l${OF_BUILD_JOBS}}"
export SOONG_UI_NINJA_ARGS="${SOONG_UI_NINJA_ARGS:--j${OF_BUILD_JOBS} -l${OF_BUILD_JOBS}}"
export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-1}"
export GOMAXPROCS="${GOMAXPROCS:-1}"
export GOGC="${GOGC:-20}"
export GOMEMLIMIT="${GOMEMLIMIT:-6GiB}"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:--Xmx1g}"
export LC_ALL="${LC_ALL:-C}"

swap_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
swap_gb="$(awk -v kb="${swap_kb}" 'BEGIN { printf "%.1f GB", kb / 1024 / 1024 }')"
min_swap_kb=$((12 * 1024 * 1024))
if [ "${OF_SKIP_SWAP_CHECK:-0}" != "1" ] && [ "${swap_kb}" -lt "${min_swap_kb}" ]; then
    cat >&2 <<EOF
Swap is too small for this low-memory Android build.
Current swap: ${swap_gb}
Recommended: at least 12 GB, preferably 16 GB

Add temporary swap, then rerun:
  sudo fallocate -l 16G /swap-build.img
  sudo chmod 600 /swap-build.img
  sudo mkswap /swap-build.img
  sudo swapon /swap-build.img

To bypass this check anyway, set OF_SKIP_SWAP_CHECK=1.
EOF
    exit 1
fi

renice -n 15 -p "$$" >/dev/null 2>&1 || true
ionice -c3 -p "$$" >/dev/null 2>&1 || true

export OUT_DIR="${OUT_DIR:-${TOP_DIR}/out}"
LOG_DIR="${OUT_DIR}/logs"
mkdir -p "${LOG_DIR}"

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
    TARGETS=(adbd vendorbootimage)
fi

LOG_FILE="${LOG_DIR}/goya-lowmem-$(date +%Y%m%d-%H%M%S).log"
PRODUCT_OUT="${OUT_DIR}/target/product/goya"

cd "${TOP_DIR}"

# fox_callback.sh mutates the assembled recovery root (module pruning, UPX,
# /sbin symlinks). A stale generated tree makes the next OrangeFox pass
# overwrite dangling links and recompress UPX files, so remove only the
# generated recovery root before each vendorbootimage build.
if printf ' %s ' "${TARGETS[*]}" | grep -q ' vendorbootimage '; then
    rm -rf "${PRODUCT_OUT}/recovery"
    rm -f "${PRODUCT_OUT}/obj/PACKAGING/recovery_intermediates/ramdisk_files-timestamp"
    # fox_callback.sh prunes modules and rewrites the recovery root, but the
    # packed recovery.cpio.lz4 is cached separately. Drop the cache so the
    # fragment is always rebuilt from the current recovery root.
    rm -rf "${PRODUCT_OUT}/obj/PACKAGING/vendor_ramdisk_fragments_intermediates"
fi

set +u
# shellcheck disable=SC1091
source build/envsetup.sh
lunch twrp_goya-ap2a-eng
set -u

echo "log: ${LOG_FILE}"
echo "targets: ${TARGETS[*]}"

# envsetup.sh's _trigger_build reads ANDROID_BUILD_BANNER without a default.
# Keep nounset disabled for the wrapper call so a successful build does not
# fail in the post-build banner.
set +e
set +u
mka -j"${OF_BUILD_JOBS}" "${TARGETS[@]}" 2>&1 | tee "${LOG_FILE}"
status=${PIPESTATUS[0]}
set -u
set -e

if [ "${status}" -ne 0 ]; then
    echo "build failed; see ${LOG_FILE}" >&2
    exit "${status}"
fi

if printf ' %s ' "${TARGETS[*]}" | grep -q ' vendorbootimage '; then
    if ! "${DEVICE_DIR}/tools/build-system-compatible-vendor-boot.sh" "${PRODUCT_OUT}"; then
        echo "system-compatible vendor_boot repack failed" >&2
        exit 1
    fi
fi

exit 0
