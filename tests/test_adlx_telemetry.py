"""Offline source/build contracts for the private ADLX diagnostic.

Physical RX 7900 XTX metric availability is deliberately not asserted here.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/adlx-telemetry.c").read_text(encoding="utf-8")
WRAPPER = (ROOT / "tools/adlx-telemetry.ps1").read_text(encoding="utf-8")
BUILDER = (ROOT / "tools/build-adlx-telemetry.sh").read_text(encoding="utf-8")


class PrivateAdlxTelemetryContracts(unittest.TestCase):
    def test_read_only_metric_allowlist(self):
        for metric in (
            "GPUClockSpeed",
            "GPUVRAMClockSpeed",
            "GPUUsage",
            "GPUTotalBoardPower",
            "GPUTemperature",
            "GPUHotspotTemperature",
        ):
            self.assertIn(f"IsSupported{metric}", SOURCE)
            self.assertRegex(SOURCE, rf"(?:INT|DOUBLE)_METRIC\([^\n]*IsSupported{metric}, {metric}\)")
        self.assertNotRegex(SOURCE, r"(?:->|\.)[A-Za-z0-9_]*(?:Set|Tuning|Overdrive)[A-Za-z0-9_]*\s*\(")

    def test_exact_system_library_and_identity(self):
        self.assertIn('L"\\\\amdadlx64.dll"', SOURCE)
        self.assertIn("LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32", SOURCE)
        for method in ("PNPString", "VendorId", "DeviceId"):
            self.assertIn(f"->pVtbl->{method}", SOURCE)
        self.assertIn('"incomplete"', SOURCE)
        self.assertIn(r'\"servingDeviceBound\"', SOURCE)

    def test_bounded_standard_user_wrapper(self):
        self.assertIn("WindowsBuiltInRole]::Administrator", WRAPPER)
        self.assertIn("Get-AuthenticodeSignature", WRAPPER)
        self.assertIn("Get-FileHash", WRAPPER)
        self.assertIn("New-Object Bitworks.FastLlm.ProcessHost", WRAPPER)
        self.assertIn("$timer.ElapsedMilliseconds -lt 60000", WRAPPER)
        self.assertIn("$hostProcess.OutputCompleted", WRAPPER)
        self.assertIn("$hostProcess.OutputTruncated", WRAPPER)
        self.assertIn("$hostProcess.Dispose()", WRAPPER)
        self.assertNotIn("WaitForExit()", WRAPPER)

    def test_exclusive_report_and_disk_provenance(self):
        self.assertIn("[Parameter(Mandatory = $true)][string]$OutputPath", WRAPPER)
        self.assertIn("OutputPath already exists", WRAPPER)
        self.assertIn("[IO.FileMode]::CreateNew", WRAPPER)
        self.assertIn("[IO.FileShare]::None", WRAPPER)
        self.assertIn("[IO.File]::Delete($reportPath)", WRAPPER)
        self.assertIn("Output path traverses a reparse point", WRAPPER)
        self.assertIn("wrapperSourceSha256", WRAPPER)
        self.assertIn("startedUtc", WRAPPER)
        self.assertIn("endedUtc", WRAPPER)
        self.assertIn("On-disk diagnostic inputs changed during sampling.", WRAPPER)
        self.assertNotIn("Out-File", WRAPPER)

    def test_pinned_sdk_and_collector(self):
        self.assertIn("32b5a740d42295c5dfe9026b9f52683da0f3af91", BUILDER)
        self.assertIn("99850ddd58e3f5bbfdbe41c87248da8d5394227eaa32b19aad3206b4c3b2677c", BUILDER)
        self.assertIn("-target x86_64-windows-gnu", BUILDER)
        self.assertIn("-D_M_AMD64", BUILDER)
        self.assertIn("-O2 -s", BUILDER)
        self.assertRegex(WRAPPER, r"\$expectedCollectorSha256 = '[0-9a-f]{64}'")
        self.assertIn("$collectorSha256 -ne $expectedCollectorSha256", WRAPPER)


if __name__ == "__main__":
    unittest.main()
