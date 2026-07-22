#pragma once

#include <cstdint>

struct NativeTrajectoryProbeSnapshot {
    uint64_t sequence = 0;
    double timestamp = 0.0;
    uint64_t objectCount = 0;
    uint64_t eligibleCount = 0;
    uint64_t activeCount = 0;
    uint64_t writeCount = 0;
    uint64_t verifyCount = 0;
    int32_t reflectNodeCount = 0;
    int32_t reflectApplied = 0;
    float scaleBefore = 0.0f;
    float scaleAfter = 0.0f;
};

extern "C" bool NativeTrajectoryCopyProbeSnapshot(
    NativeTrajectoryProbeSnapshot* output);
