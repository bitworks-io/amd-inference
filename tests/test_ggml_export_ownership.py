"""Offline ownership audit for the pinned b10698 Windows Vulkan GGML ABI."""

import hashlib
import os
from pathlib import Path
import struct
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_SHA256 = "31e2fe70d4864a4ae6a4e7d8e102ee9203ba18963077e7727c54f9bd6ae3bea5"
DLL_SHA256 = {
    "ggml-base.dll": "16bfb54f4676e592aa977d681f6d4c570fd3c8fc0a2944653c106c6d961a9dae",
    "ggml.dll": "483616cd48e88fccb26820417600df7d00d7dd1d6aab608f91df620d09ca831a",
    "ggml-vulkan.dll": "8b2b59ad66f07894b6886c84ba4ddde9c19c1984a0aa9d885a58e2d8c518381d",
}
OWNERS = {
    "ggml_log_get": "ggml-base.dll",
    "ggml_log_set": "ggml-base.dll",
    "ggml_backend_dev_get_props": "ggml-base.dll",
    "ggml_backend_load": "ggml.dll",
    "ggml_backend_dev_by_name": "ggml.dll",
}


def pe_exports(data: bytes) -> set[str]:
    """Read only named PE32+ exports; reject malformed offsets and strings."""
    def u16(offset: int) -> int:
        return struct.unpack_from("<H", data, offset)[0]

    def u32(offset: int) -> int:
        return struct.unpack_from("<I", data, offset)[0]

    if data[:2] != b"MZ":
        raise ValueError("Not a PE image")
    pe = u32(0x3C)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Missing PE signature")
    sections = u16(pe + 6)
    opt_size = u16(pe + 20)
    opt = pe + 24
    if u16(opt) != 0x20B or sections < 1 or sections > 96:
        raise ValueError("Not a bounded PE32+ image")
    export_rva = u32(opt + 112)
    section_table = opt + opt_size

    def offset_for(rva: int) -> int:
        for i in range(sections):
            section = section_table + 40 * i
            virtual_size = u32(section + 8)
            virtual_address = u32(section + 12)
            raw_size = u32(section + 16)
            raw_address = u32(section + 20)
            if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
                result = raw_address + rva - virtual_address
                if result >= len(data):
                    break
                return result
        raise ValueError("Export RVA outside image")

    directory = offset_for(export_rva)
    count = u32(directory + 24)
    names_rva = u32(directory + 32)
    if count > 65536:
        raise ValueError("Excessive export count")
    names_offset = offset_for(names_rva)
    result = set()
    for i in range(count):
        name_rva = u32(names_offset + 4 * i)
        start = offset_for(name_rva)
        end = data.find(b"\0", start, min(start + 128, len(data)))
        if end < 0:
            raise ValueError("Unterminated export name")
        result.add(data[start:end].decode("ascii"))
    return result


class GgmlExportOwnershipTests(unittest.TestCase):
    def test_source_looks_up_each_symbol_in_audited_dll(self):
        source = (ROOT / "src" / "WindowsGgmlVulkanCapabilities.cs").read_text()
        self.assertIn('Symbol<LogGet>(baseDll, "ggml_log_get")', source)
        self.assertIn('Symbol<LogSet>(baseDll, "ggml_log_set")', source)
        self.assertIn('Symbol<DeviceProps>(baseDll, "ggml_backend_dev_get_props")', source)
        self.assertIn('Symbol<BackendLoad>(core, "ggml_backend_load")', source)
        self.assertIn('Symbol<DeviceByName>(core, "ggml_backend_dev_by_name")', source)

    @unittest.skipUnless(os.environ.get("FASTLLM_B10698_VULKAN_ARCHIVE"), "set exact pinned archive path for PE export audit")
    def test_exact_pinned_archive_exports(self):
        archive = Path(os.environ["FASTLLM_B10698_VULKAN_ARCHIVE"])
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), ARCHIVE_SHA256)
        exports = {}
        with zipfile.ZipFile(archive) as zipped:
            for name, digest in DLL_SHA256.items():
                data = zipped.read(name)
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                exports[name] = pe_exports(data)
        for symbol, owner in OWNERS.items():
            self.assertEqual([name for name in DLL_SHA256 if symbol in exports[name]], [owner], symbol)


if __name__ == "__main__":
    unittest.main()
