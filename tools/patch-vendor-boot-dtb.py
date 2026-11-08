#!/usr/bin/env python3
"""Remove the MediaTek USB offload property from a vendor_boot DTB.

The MTK DTB shipped in vendor_boot starts with a 64-byte MediaTek header and
contains an embedded flattened device tree at offset 0x40.  The
`mediatek,usb-offload` property makes mtu3 reject host-mode transitions while
no audio/MD offload provider is registered.  Recovery does not run that
provider, so the optional property is deleted from a temporary copy.

Usage:
    patch-vendor-boot-dtb.py --input dtb --output dtb.patched
    patch-vendor-boot-dtb.py --input dtb --check-absent mediatek,usb-offload

The --check-absent mode verifies the flattened device tree structurally. A
plain `strings` search is not enough: the property name may remain in the
unused part of the FDT string table, or the same text may appear as a
`compatible` value of a different node.
"""

from __future__ import annotations

import argparse
import struct
import sys

# The MTK wrapper stores the magic d7 b7 ab 1e on disk; reading it as a
# little-endian u32 yields 0x1eabb7d7.
MTK_MAGIC = 0x1EABB7D7
MTK_HEADER_SIZE = 64
FDT_MAGIC = 0xD00DFEED

FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9


def align4(value: int) -> int:
    return (value + 3) & ~3


class Fdt:
    def __init__(self, data: bytes, offset: int = 0):
        self.data = data
        self.offset = offset
        if len(data) < offset + 40:
            raise ValueError("input is smaller than an FDT header")
        fields = struct.unpack_from(">10I", data, offset)
        (magic, totalsize, off_struct, off_strings, off_rsvmap,
         version, last_comp_version, boot_cpuid, size_strings,
         size_struct) = fields
        if magic != FDT_MAGIC:
            raise ValueError(f"bad FDT magic 0x{magic:08x} at offset 0x{offset:x}")
        if version < 16:
            raise ValueError(f"unsupported FDT version {version}")
        self.totalsize = totalsize
        self.off_struct = off_struct
        self.off_strings = off_strings
        self.off_rsvmap = off_rsvmap
        self.version = version
        self.last_comp_version = last_comp_version
        self.boot_cpuid = boot_cpuid
        self.size_strings = size_strings
        self.size_struct = size_struct
        if offset + totalsize > len(data):
            raise ValueError("FDT totalsize exceeds input length")

    def strip_property(self, property_name: str) -> int:
        start = self.offset + self.off_struct
        end = start + self.size_struct
        strings = self.data[self.offset + self.off_strings:
                            self.offset + self.off_strings + self.size_strings]

        def string_at(nameoff: int) -> str:
            if nameoff >= len(strings):
                raise ValueError("FDT property name offset out of range")
            tail = strings[nameoff:]
            return tail.split(b"\x00", 1)[0].decode("ascii", "replace")

        out = bytearray()
        removed = 0
        pos = start
        depth = 0
        while pos < end:
            token = struct.unpack_from(">I", self.data, pos)[0]
            token_start = pos
            pos += 4
            if token == FDT_BEGIN_NODE:
                nul = self.data.index(b"\x00", pos, end)
                pos = align4(nul + 1)
                depth += 1
                out += self.data[token_start:pos]
            elif token == FDT_END_NODE:
                depth -= 1
                out += self.data[token_start:pos]
            elif token == FDT_PROP:
                if pos + 8 > end:
                    raise ValueError("truncated FDT property header")
                length, nameoff = struct.unpack_from(">II", self.data, pos)
                pos += 8
                value_start = pos
                pos = align4(pos + length)
                if string_at(nameoff) == property_name:
                    removed += 1
                else:
                    out += self.data[token_start:pos]
            elif token == FDT_NOP:
                # NOP tokens carry no data. Dropping them shrinks the blob.
                pass
            elif token == FDT_END:
                out += self.data[token_start:pos]
                if pos != end:
                    # Some generators pad the structure block. Keep the
                    # remaining alignment padding out of the rebuilt block;
                    # the header size is authoritative.
                    pass
                break
            else:
                raise ValueError(f"unknown FDT token 0x{token:x} at 0x{pos - 4:x}")

        if depth != 0:
            raise ValueError("unbalanced FDT structure block")
        self._new_struct = bytes(out)
        self._new_size_struct = len(out)
        return removed

    def rebuild(self) -> bytes:
        if not hasattr(self, "_new_struct"):
            raise RuntimeError("strip_property() must be called first")

        # Preserve the header plus memory reservation map exactly as they were
        # laid out. They are between the FDT header (40 bytes) and the
        # structure block.
        prefix = self.data[self.offset:self.offset + self.off_struct]
        strings = self.data[self.offset + self.off_strings:
                            self.offset + self.off_strings + self.size_strings]
        off_struct = len(prefix)
        off_strings = align4(off_struct + self._new_size_struct)
        total = off_strings + self.size_strings
        blob = bytearray(total)
        blob[:len(prefix)] = prefix
        struct.pack_into(">10I", blob, 0,
                         FDT_MAGIC, total, off_struct, off_strings,
                         self.off_rsvmap, self.version,
                         self.last_comp_version, self.boot_cpuid,
                         self.size_strings, self._new_size_struct)
        blob[off_struct:off_struct + self._new_size_struct] = self._new_struct
        blob[off_strings:off_strings + self.size_strings] = strings
        return bytes(blob)


def open_mtk_fdt(data: bytes) -> tuple[Fdt, int]:
    if len(data) < MTK_HEADER_SIZE:
        raise ValueError("DTB is smaller than the MTK header")
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MTK_MAGIC:
        raise ValueError(f"bad MTK DTB magic 0x{magic:08x}")
    fdt_size = struct.unpack_from(">I", data, 0x20)[0]
    fdt_offset = struct.unpack_from(">I", data, 0x24)[0]
    if fdt_offset + fdt_size > len(data):
        raise ValueError("MTK FDT size/offset exceed the input length")
    return Fdt(data[fdt_offset:fdt_offset + fdt_size]), fdt_offset


def patch_mtk_dtb(data: bytes) -> tuple[bytes, int]:
    fdt, fdt_offset = open_mtk_fdt(data)
    removed = fdt.strip_property("mediatek,usb-offload")
    new_fdt = fdt.rebuild()

    # Keep the 64-byte MTK wrapper, but refresh the two size fields that the
    # bootloader uses to validate the blob.
    header = bytearray(data[:fdt_offset])
    struct.pack_into(">I", header, 0x04, fdt_offset + len(new_fdt))
    struct.pack_into(">I", header, 0x20, len(new_fdt))
    struct.pack_into(">I", header, 0x24, fdt_offset)

    output = bytes(header) + new_fdt
    # Sanity check the rebuilt FDT.
    check = Fdt(output[fdt_offset:])
    if check.totalsize != len(new_fdt):
        raise ValueError("rebuilt FDT length mismatch")
    return output, removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output")
    parser.add_argument("--allow-missing", action="store_true",
                        help="copy the input unchanged if the property is absent")
    parser.add_argument("--check-absent", metavar="PROPERTY",
                        help="only verify that no property with this name exists")
    args = parser.parse_args()

    with open(args.input, "rb") as handle:
        data = handle.read()

    if args.check_absent:
        try:
            fdt, _ = open_mtk_fdt(data)
            present = fdt.strip_property(args.check_absent)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        if present:
            print(f"error: DTB still declares property {args.check_absent}",
                  file=sys.stderr)
            return 1
        print(f"checked DTB: property {args.check_absent} is absent")
        return 0

    if not args.output:
        parser.error("--output is required unless --check-absent is used")

    try:
        output, removed = patch_mtk_dtb(data)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if removed == 0:
        if args.allow_missing:
            print("mediatek,usb-offload not present; copying input unchanged")
            output = data
        else:
            print("error: mediatek,usb-offload not found in DTB", file=sys.stderr)
            return 1

    with open(args.output, "wb") as handle:
        handle.write(output)
    print(f"patched DTB: {args.output} "
          f"({len(data)} -> {len(output)} bytes, {removed} properties removed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
