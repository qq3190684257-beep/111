from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OVERLAY = (ROOT / "src" / "Overlay.mm").read_text(encoding="utf-8")
BRIDGE = (ROOT / "src" / "IL2CPPBridge.mm").read_text(encoding="utf-8")
BRIDGE_HEADER = (ROOT / "src" / "IL2CPPBridge.hpp").read_text(encoding="utf-8")
NATIVE = (ROOT / "src" / "NativeTrajectory.mm").read_text(encoding="utf-8")
PROBE_HEADER = (ROOT / "src" / "NativeTrajectoryProbe.hpp").read_text(
    encoding="utf-8"
)
MAKEFILE = (ROOT / "Makefile").read_text(encoding="utf-8")
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def main() -> None:
    draw_start = OVERLAY.index(
        "if (_predictionEnabled && _snapshot.aimingActive) {"
    )
    draw_end = OVERLAY.index("CGContextRestoreGState(context);", draw_start)
    draw_block = OVERLAY[draw_start:draw_end]

    assert "cueApproachScreenRoute" not in draw_block
    assert "_snapshot.cueAfterScreenRoute" in draw_block
    assert "_snapshot.targetScreenRoute" in draw_block
    assert "cueApproachScreenRoute" in BRIDGE
    assert "plugin_version=0.1.0-match-probe-no-yellow" in OVERLAY
    assert "replica_object_count" in OVERLAY
    assert "NativeTrajectoryCopyProbeSnapshot" in OVERLAY
    assert "usedFixedFallback" in BRIDGE
    assert "usedFixedFallback" in BRIDGE_HEADER
    assert "-1.3335f" in BRIDGE_HEADER
    assert "-0.7963796f" in BRIDGE_HEADER
    assert "physics.outerBoundsScreen" in OVERLAY
    assert "marker != 64" not in NATIVE
    assert "marker < 0 || marker > 4096" in NATIVE
    assert "gLatestProbeSnapshot" in NATIVE
    assert "NativeTrajectoryCopyProbeSnapshot" in PROBE_HEADER
    assert VERSION == "0.1.0-match-probe-no-yellow-fixed-table"
    assert "tests/source_contract_tests.py" in MAKEFILE
    assert "src/NativeTrajectory.mm" in MAKEFILE
    assert "PRODUCT := NativeTrajectory" in MAKEFILE
    assert "RELEASE_NOTES_0.1.0.md" in MAKEFILE
    print("source contract ok: no-yellow match probe with fixed-table fallback")


if __name__ == "__main__":
    main()
