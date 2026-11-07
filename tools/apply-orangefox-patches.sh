#!/usr/bin/env bash
#
# Apply the single generic OrangeFox build/make patch required by goya.
#
# This script deliberately does not apply the rodin-specific
# orangefox-recovery.patch or orangefox-vendor-twrp.patch. Goya uses the
# unmodified OrangeFox 14.1 recovery UI, AIDL BootControl from the stock
# platform fragment and the stock vendor_dlkm touch modules.
#
# Usage:
#   tools/apply-orangefox-patches.sh [OrangeFox source root]
#
set -euo pipefail

DEVICE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOP_DIR="${1:-${ORANGEFOX_TOP:-$(cd -- "${DEVICE_DIR}/../../.." && pwd -P)}}"
BUILD_DIR="${TOP_DIR}/build/make"
BUILD_PATCH="${DEVICE_DIR}/patches/orangefox-build-make.patch"
EXPECTED_BUILD_PATCH_SHA256="5f2d3f43a4d78eee6d560a4a169df30fc95de6fa2ed294e3210e684a641a8329"

apply_patch_once() {
    local repository="$1"
    local patch_file="$2"
    local label="$3"

    if ! git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: ${label} repository not found: ${repository}" >&2
        exit 1
    fi
    if [ ! -s "$patch_file" ]; then
        echo "ERROR: patch file not found: ${patch_file}" >&2
        exit 1
    fi

    if git -C "$repository" apply --whitespace=nowarn --reverse --check "$patch_file" 2>/dev/null; then
        echo "${label} patch is already applied"
    else
        git -C "$repository" apply --whitespace=nowarn --check "$patch_file"
        git -C "$repository" apply --whitespace=nowarn "$patch_file"
        echo "Applied ${patch_file}"
    fi
}

for command_name in git grep python3 sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required host command not found: $command_name" >&2
        exit 1
    }
done

if [ ! -f "${TOP_DIR}/build/envsetup.sh" ]; then
    echo "ERROR: not an OrangeFox source root: ${TOP_DIR}" >&2
    echo "Pass the source root as the first argument or set ORANGEFOX_TOP." >&2
    exit 1
fi
if [ ! -d "$BUILD_DIR" ] || [ ! -d "${TOP_DIR}/vendor/twrp" ] || [ ! -d "${TOP_DIR}/bootable/recovery" ]; then
    echo "ERROR: OrangeFox build/make, vendor/twrp or bootable/recovery is missing" >&2
    exit 1
fi

check_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: unexpected SHA-256 for $file" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
}

check_sha256 "$BUILD_PATCH" "$EXPECTED_BUILD_PATCH_SHA256"
apply_patch_once "$BUILD_DIR" "$BUILD_PATCH" "OrangeFox build/make"

# The OrangeFox sync repository must provide the post-build hook and the
# OrangeFox 14.1 recovery makefiles. These are not part of AOSP.
if [ ! -f "${TOP_DIR}/vendor/recovery/OrangeFox_A14.sh" ]; then
    echo "ERROR: OrangeFox post-build hook is missing: vendor/recovery/OrangeFox_A14.sh" >&2
    echo "Sync the full pinned OrangeFox 14.1 manifest before using this patch." >&2
    exit 1
fi
if [ ! -f "${TOP_DIR}/bootable/recovery/orangefox.mk" ] && \
        [ ! -f "${TOP_DIR}/bootable/recovery/orangefox_defaults.go" ]; then
    echo "ERROR: bootable/recovery is not an OrangeFox 14.1 checkout" >&2
    exit 1
fi

for marker in Fox_Before_Recovery_Image orangefox_envsetup BUILD_BROKEN_PLUGIN_VALIDATION; do
    if ! grep -RqsF -- "$marker" "$BUILD_DIR"; then
        echo "ERROR: build/make patch marker missing after apply: $marker" >&2
        exit 1
    fi
done
if grep -RqsF -- 'COMPRESSION_COMMANDR' "$BUILD_DIR"; then
    echo "ERROR: build/make contains the misspelled COMPRESSION_COMMANDR" >&2
    exit 1
fi

if ! grep -RqsF -- 'OF_USE_AIDL_BOOT_CONTROL' "${TOP_DIR}/vendor/twrp"; then
    echo "ERROR: OrangeFox vendor/twrp does not expose OF_USE_AIDL_BOOT_CONTROL" >&2
    exit 1
fi
if [ ! -f "${TOP_DIR}/bootable/recovery/gui/theme/common/languages/it_IT.xml" ]; then
    echo "ERROR: OrangeFox 14.1 has no Italian language file (it_IT.xml)" >&2
    exit 1
fi

ORANGEFOX_TOP="$TOP_DIR" "${DEVICE_DIR}/tools/verify-build-inputs.sh"
echo "OrangeFox goya source patches and device inputs are ready"
