#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

#include "../src/Geometry.hpp"

namespace {

bool near(float actual, float expected, float tolerance = 1.0e-4f) {
    return std::fabs(actual - expected) <= tolerance;
}

}  // namespace

int main() {
    using namespace poollab;

    const Bounds2 table{{-1.0f, -0.5f}, {1.0f, 0.5f}};
    const float radius = 0.05f;

    const std::vector<Ball2> straightBalls{
        {0, {0.0f, 0.0f}, true},
        {1, {0.5f, 0.0f}, true},
    };
    const Prediction straight = predict(
        straightBalls, 0, {1.0f, 0.0f}, radius, table, false);
    assert(straight.targetIndex == 1);
    assert(straight.cueApproachRoute.count == 1);
    assert(near(straight.cueApproachRoute.segments[0].b.x, 0.4f));
    assert(straight.targetRoute.count >= 1);
    assert(straight.cueAfterRoute.count == 0);

    // A cut shot must retain both post-contact routes. Overlay color choices
    // are independent from this geometry and are checked by the source test.
    const std::vector<Ball2> cutBalls{
        {0, {0.0f, 0.0f}, true},
        {1, {0.5f, 0.05f}, true},
    };
    const Prediction cut = predict(
        cutBalls, 0, {1.0f, 0.0f}, radius, table, false);
    assert(cut.targetIndex == 1);
    assert(cut.cueApproachRoute.count == 1);
    assert(cut.targetRoute.count >= 1);
    assert(cut.cueAfterRoute.count >= 1);

    const Vec2 reflected = reflectedAtRail(
        normalized({1.0f, 1.0f}), {0.95f, 0.2f},
        {{-0.95f, -0.45f}, {0.95f, 0.45f}});
    assert(reflected.x < 0.0f);
    assert(reflected.y > 0.0f);

    std::cout << "geometry tests passed\n";
    return 0;
}
