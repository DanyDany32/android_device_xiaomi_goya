#!/usr/bin/env python3
"""Unpack an Android vendor_boot image (header v3/v4, including MediaTek v4).

The script extracts every vendor ramdisk fragment, the DTB, the bootconfig and
a small JSON description used by the repack script. It never modifies the input
image and works with the stock Xiaomi 15T (goya) vendor_boot layout.

Usage:
    unpack-vendor-boot.py --input vendor_boot.img --out prebuilt/vendor-boot
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

VENDOR_BOOT_MAGIC = b"VNDRBOOT"
VENDOR_BOOT_ARGS_SIZE = 2048
VENDOR_BOOT_NAME_SIZE = 16
RAMDISK_NAME_SIZE = 32
BOARD_ID_SIZE = 16
VENDOR_HEADER_V3_SIZE = 2112
VENDOR_HEADER_V4_SIZE = 2128

RAMDISK_TYPES = {
    0: "none",
    1: "platform",
    2: "recovery",
    3: "dlkm",
}


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def cstr(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")


class VendorBoot:
    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 8 or data[:8] != VENDOR_BOOT_MAGIC:
            raise ValueError("input is not a vendor_boot image (bad magic)")
        self.header_version = struct.unpack_from("<I", data, 8)[0]
        self.page_size = struct.unpack_from("<I", data, 12)[0]
        self.kernel_addr = struct.unpack_from("<I", data, 16)[0]
        self.ramdisk_addr = struct.unpack_from("<I", data, 20)[0]
        self.vendor_ramdisk_size = struct.unpack_from("<I", data, 24)[0]
        self.cmdline = cstr(data[28:28 + VENDOR_BOOT_ARGS_SIZE])
        self.tags_addr = struct.unpack_from("<I", data, 28 + VENDOR_BOOT_ARGS_SIZE)[0]
        name_offset = 32 + VENDOR_BOOT_ARGS_SIZE
        self.name = cstr(data[name_offset:name_offset + VENDOR_BOOT_NAME_SIZE])
        self.header_size = struct.unpack_from("<I", data, name_offset + VENDOR_BOOT_NAME_SIZE)[0]
        self.dtb_size = struct.unpack_from("<I", data, name_offset + VENDOR_BOOT_NAME_SIZE + 4)[0]
        self.dtb_addr = struct.unpack_from("<Q", data, name_offset + VENDOR_BOOT_NAME_SIZE + 8)[0]

        if self.header_version < 3:
            raise ValueError(f"vendor_boot v{self.header_version} has no ramdisk table; "
                             "only v3/v4 are supported")
        table_offset = name_offset + VENDOR_BOOT_NAME_SIZE + 16
        self.table_size = struct.unpack_from("<I", data, table_offset)[0]
        self.table_entry_num = struct.unpack_from("<I", data, table_offset + 4)[0]
        self.table_entry_size = struct.unpack_from("<I", data, table_offset + 8)[0]
        self.bootconfig_size = 0
        if self.header_version >= 4:
            self.bootconfig_size = struct.unpack_from("<I", data, table_offset + 12)[0]

        if self.page_size == 0 or self.page_size & (self.page_size - 1):
            raise ValueError(f"invalid vendor_boot page size {self.page_size}")
        min_header = VENDOR_HEADER_V4_SIZE if self.header_version >= 4 else VENDOR_HEADER_V3_SIZE
        if self.header_size < min_header:
            raise ValueError(f"vendor_boot header size {self.header_size} is "
                             f"smaller than v{self.header_version} minimum {min_header}")

        self.header_pages = align_up(self.header_size, self.page_size) // self.page_size
        self.ramdisk_offset = self.page_size * self.header_pages
        self.dtb_offset = align_up(self.ramdisk_offset + self.vendor_ramdisk_size,
                                   self.page_size)
        self.table_offset = align_up(self.dtb_offset + self.dtb_size, self.page_size)
        self.bootconfig_offset = align_up(self.table_offset + self.table_size,
                                          self.page_size)
        image_end = self.bootconfig_offset + self.bootconfig_size
        if image_end > len(data):
            raise ValueError(f"vendor_boot sections end at {image_end}, "
                             f"but the file is only {len(data)} bytes")

        self.entries = self._parse_table()

    def _parse_table(self) -> list[dict]:
        entries = []
        base = self.table_offset
        for index in range(self.table_entry_num):
            offset = base + index * self.table_entry_size
            if offset + 12 + RAMDISK_NAME_SIZE + 4 * BOARD_ID_SIZE > len(self.data):
                raise ValueError("vendor ramdisk table is truncated")
            (ramdisk_size, ramdisk_offset, ramdisk_type) = struct.unpack_from("<III",
                                                                             self.data, offset)
            name_offset = offset + 12
            name = cstr(self.data[name_offset:name_offset + RAMDISK_NAME_SIZE])
            board_ids = struct.unpack_from(f"<{BOARD_ID_SIZE}I", self.data,
                                           name_offset + RAMDISK_NAME_SIZE)
            absolute = self.ramdisk_offset + ramdisk_offset
            if absolute + ramdisk_size > len(self.data):
                raise ValueError(f"ramdisk fragment {index} exceeds the image")
            entries.append({
                "index": index,
                "name": name,
                "type": ramdisk_type,
                "type_name": RAMDISK_TYPES.get(ramdisk_type, f"unknown({ramdisk_type})"),
                "size": ramdisk_size,
                "offset": ramdisk_offset,
                "absolute_offset": absolute,
                "board_id": list(board_ids),
            })
        return entries

    def extract(self, out_dir: str) -> dict:
        os.makedirs(out_dir, exist_ok=True)

        for entry in self.entries:
            path = os.path.join(out_dir, f"vendor_ramdisk{entry['index']:02d}")
            with open(path, "wb") as handle:
                handle.write(self.data[entry["absolute_offset"]:
                                       entry["absolute_offset"] + entry["size"]])
            entry["file"] = os.path.basename(path)

        dtb_path = os.path.join(out_dir, "dtb")
        with open(dtb_path, "wb") as handle:
            handle.write(self.data[self.dtb_offset:self.dtb_offset + self.dtb_size])

        bootconfig_path = os.path.join(out_dir, "bootconfig")
        with open(bootconfig_path, "wb") as handle:
            handle.write(self.data[self.bootconfig_offset:
                                   self.bootconfig_offset + self.bootconfig_size])

        info = {
            "magic": VENDOR_BOOT_MAGIC.decode("ascii"),
            "header_version": self.header_version,
            "page_size": self.page_size,
            "kernel_addr": self.kernel_addr,
            "ramdisk_addr": self.ramdisk_addr,
            "vendor_ramdisk_size": self.vendor_ramdisk_size,
            "vendor_cmdline": self.cmdline,
            "tags_addr": self.tags_addr,
            "name": self.name,
            "header_size": self.header_size,
            "dtb_size": self.dtb_size,
            "dtb_addr": self.dtb_addr,
            "dtb_file": "dtb",
            "bootconfig_size": self.bootconfig_size,
            "bootconfig_file": "bootconfig",
            "image_size": len(self.data),
            "ramdisk_table": self.entries,
        }
        with open(os.path.join(out_dir, "header.json"), "w", encoding="utf-8") as handle:
            json.dump(info, handle, indent=2, sort_keys=False)
            handle.write("\n")
        return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="stock vendor_boot.img")
    parser.add_argument("--out", required=True, help="output directory")
    args = parser.parse_args()

    with open(args.input, "rb") as handle:
        data = handle.read()

    try:
        image = VendorBoot(data)
        info = image.extract(args.out)
    except (ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"vendor_boot v{info['header_version']}, page size {info['page_size']}")
    print(f"vendor cmdline: {info['vendor_cmdline']!r}")
    print(f"dtb: {info['dtb_size']} bytes, bootconfig: {info['bootconfig_size']} bytes")
    for entry in info["ramdisk_table"]:
        print(f"  {entry['file']}: type={entry['type_name']} "
              f"name={entry['name']!r} size={entry['size']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
