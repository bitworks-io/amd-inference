"""Offline contracts for private ADLX v2 VRAM diagnostics; not hardware tests."""

import hashlib
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
V1 = ROOT / "tools/adlx-telemetry.c"
SOURCE = (ROOT / "tools/adlx-vram-diagnostic.c").read_text(encoding="utf-8")
WRAPPER = (ROOT / "tools/adlx-vram-diagnostic.ps1").read_text(encoding="utf-8")
BUILDER = (ROOT / "tools/build-adlx-vram-diagnostic.sh").read_text(encoding="utf-8")


class PrivateAdlxVramContracts(unittest.TestCase):
    def test_v1_unchanged_and_pinned(self):
        self.assertEqual(
            hashlib.sha256(V1.read_bytes()).hexdigest(),
            "f40506f015e3dd6ecaa9f11671ff3cc127896b539faac18ae572a12a4bb16a24",
        )
        self.assertIn('#include "adlx-telemetry.c"', SOURCE)
        self.assertIn("v1_source_sha256='f40506f015e3dd6ecaa9f11671ff3cc127896b539faac18ae572a12a4bb16a24'", BUILDER)

    def test_exact_sdk_getters_and_lifetimes(self):
        for interface in (
            "IADLXGPUMetricsSupport1",
            "IADLXGPUMetrics1",
            "IADLXManualVRAMTuning2",
            "IADLXManualPowerTuning",
            "IADLXGPUPresetTuning",
        ):
            self.assertIn(f"IID_{interface}()", SOURCE)
        for method in (
            "IsSupportedGPUMemoryTemperature", "GPUMemoryTemperature",
            "IsAtFactory", "GetMaxVRAMFrequency", "GetMaxVRAMFrequencyRange",
            "GetPowerLimit", "GetPowerLimitRange", "IsCurrentQuiet",
            "IsCurrentBalanced", "IsCurrentTurbo", "IsCurrentRage",
            "IsCurrentPowerSaver",
        ):
            self.assertIn(method, SOURCE)
        self.assertIn("if (m1) m1->pVtbl->Release(m1)", SOURCE)
        self.assertIn("if (s1) s1->pVtbl->Release(s1)", SOURCE)
        for name in ("vram", "vramBase", "power", "powerBase", "preset", "presetBase"):
            self.assertIn(f"if (extra[i].{name}) extra[i].{name}->pVtbl->Release(extra[i].{name})", SOURCE)
        self.assertNotRegex(SOURCE, r"->pVtbl->[A-Za-z0-9_]*(?:Set|Reset|Start|Stop)[A-Za-z0-9_]*\s*\(")

    def test_distinct_observation_and_settings(self):
        self.assertIn('"configuredMaxVramMHz"', SOURCE)
        self.assertIn('"vramTunableMaxRangeMHz"', SOURCE)
        self.assertIn('"manualPowerLimitPercent"', SOURCE)
        self.assertIn('"powerTunableRangePercent"', SOURCE)
        self.assertIn(r'\"memoryTemperatureC\"', SOURCE)
        self.assertIn(r'\"settingsProveEffectiveCap\":false', SOURCE)
        self.assertIn("service-unavailable", SOURCE)
        self.assertIn("unsupported", SOURCE)
        self.assertIn("interface-unavailable", SOURCE)

    def test_private_wrapper_and_build(self):
        self.assertIn("[Parameter(Mandatory = $true)][string]$OutputPath", WRAPPER)
        self.assertIn("[IO.FileMode]::CreateNew", WRAPPER)
        self.assertIn("$timer.ElapsedMilliseconds -lt 60000", WRAPPER)
        self.assertIn("$hostProcess.OutputCompleted", WRAPPER)
        self.assertIn("$hostProcess.OutputTruncated", WRAPPER)
        self.assertIn("baseSamples = $baseRows", WRAPPER)
        self.assertIn("vramDiagnosticSamples = $vramRows", WRAPPER)
        self.assertIn("ADLX base and VRAM samples are not paired", WRAPPER)
        self.assertRegex(WRAPPER, r"\$expectedCollectorSha256 = '[0-9a-f]{64}'")
        self.assertIn("32b5a740d42295c5dfe9026b9f52683da0f3af91", BUILDER)
        self.assertIn("-O2 -s", BUILDER)


if __name__ == "__main__":
    unittest.main()
