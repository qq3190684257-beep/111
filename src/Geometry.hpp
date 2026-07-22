#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include <vector>

namespace poollab {

constexpr float kEpsilon = 1.0e-5f;
constexpr int kMinimumRailBounces = 1;
constexpr int kMaximumRailBounces = 6;
constexpr std::size_t kTrajectoryRouteCapacity =
    static_cast<std::size_t>(kMaximumRailBounces + 1);

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
};

struct Bounds2 {
    Vec2 min;
    Vec2 max;

    bool valid() const {
        return std::isfinite(min.x) && std::isfinite(min.y) &&
               std::isfinite(max.x) && std::isfinite(max.y) &&
               max.x > min.x && max.y > min.y;
    }
};

struct Ball2 {
    int index = -1;
    Vec2 center;
    bool active = false;
};

struct Segment2 {
    Vec2 a;
    Vec2 b;
    bool valid = false;
};

struct TrajectoryRoute {
    std::array<Segment2, kTrajectoryRouteCapacity> segments{};
    int count = 0;
};

struct Prediction {
    int targetIndex = -1;
    float cueTravelToTarget = std::numeric_limits<float>::infinity();
    Segment2 cueBefore;
    Segment2 cueRailBounce;
    Segment2 cueAfter;
    Segment2 cueAfterRailBounce;
    Segment2 target;
    Segment2 targetRailBounce;
    TrajectoryRoute cueApproachRoute;
    TrajectoryRoute cueAfterRoute;
    TrajectoryRoute targetRoute;
};

inline Vec2 operator+(Vec2 a, Vec2 b) { return {a.x + b.x, a.y + b.y}; }
inline Vec2 operator-(Vec2 a, Vec2 b) { return {a.x - b.x, a.y - b.y}; }
inline Vec2 operator*(Vec2 a, float s) { return {a.x * s, a.y * s}; }
inline float dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
inline float lengthSquared(Vec2 a) { return dot(a, a); }
inline float length(Vec2 a) { return std::sqrt(lengthSquared(a)); }

inline Vec2 normalized(Vec2 a) {
    const float n = length(a);
    return n > kEpsilon ? a * (1.0f / n) : Vec2{};
}

inline bool finite(Vec2 a) { return std::isfinite(a.x) && std::isfinite(a.y); }

// PhysicsCoordinate.DAI_Rx/DAI_Ry are full table dimensions on build 3.61.0.
// The returned bounds describe the outer cushion rectangle; predict() performs
// the single ball-radius inset needed for cue-ball center rail contacts.
inline Bounds2 boundsFromFullDimensions(Vec2 fullSize, float scale, Vec2 offset) {
    if (!finite(fullSize) || !finite(offset) || !std::isfinite(scale) ||
        fullSize.x <= kEpsilon || fullSize.y <= kEpsilon ||
        std::fabs(scale) <= kEpsilon) return {};
    const Vec2 half{fullSize.x * std::fabs(scale) * 0.5f,
                    fullSize.y * std::fabs(scale) * 0.5f};
    return {{offset.x - half.x, offset.y - half.y},
            {offset.x + half.x, offset.y + half.y}};
}

inline float rayToInnerBounds(Vec2 origin, Vec2 direction, const Bounds2& bounds) {
    if (!bounds.valid() || !finite(origin)) return 0.0f;
    direction = normalized(direction);
    if (lengthSquared(direction) < kEpsilon) return 0.0f;

    float best = std::numeric_limits<float>::infinity();
    auto consider = [&](float t, float other, float low, float high) {
        if (t > kEpsilon && other >= low - kEpsilon && other <= high + kEpsilon) {
            best = std::min(best, t);
        }
    };

    if (std::fabs(direction.x) > kEpsilon) {
        float t = (bounds.min.x - origin.x) / direction.x;
        consider(t, origin.y + t * direction.y, bounds.min.y, bounds.max.y);
        t = (bounds.max.x - origin.x) / direction.x;
        consider(t, origin.y + t * direction.y, bounds.min.y, bounds.max.y);
    }
    if (std::fabs(direction.y) > kEpsilon) {
        float t = (bounds.min.y - origin.y) / direction.y;
        consider(t, origin.x + t * direction.x, bounds.min.x, bounds.max.x);
        t = (bounds.max.y - origin.y) / direction.y;
        consider(t, origin.x + t * direction.x, bounds.min.x, bounds.max.x);
    }
    return std::isfinite(best) ? best : 0.0f;
}

inline bool firstBallHit(const std::vector<Ball2>& balls,
                         int cueIndex,
                         Vec2 direction,
                         float radius,
                         int& targetIndex,
                         float& cueCenterTravel) {
    targetIndex = -1;
    cueCenterTravel = std::numeric_limits<float>::infinity();
    if (cueIndex < 0 || static_cast<std::size_t>(cueIndex) >= balls.size() ||
        !balls[cueIndex].active || radius <= 0.0f) {
        return false;
    }

    direction = normalized(direction);
    if (lengthSquared(direction) < kEpsilon) return false;
    const Vec2 origin = balls[cueIndex].center;
    const float collisionRadius = 2.0f * radius;
    const float collisionRadius2 = collisionRadius * collisionRadius;

    for (std::size_t i = 0; i < balls.size(); ++i) {
        if (static_cast<int>(i) == cueIndex || !balls[i].active) continue;
        const Vec2 rel = balls[i].center - origin;
        const float projection = dot(rel, direction);
        if (projection <= 0.0f) continue;
        const float perpendicular2 = std::max(0.0f, lengthSquared(rel) - projection * projection);
        if (perpendicular2 > collisionRadius2) continue;
        const float travel = projection - std::sqrt(std::max(0.0f, collisionRadius2 - perpendicular2));
        if (travel > kEpsilon && travel < cueCenterTravel) {
            cueCenterTravel = travel;
            targetIndex = static_cast<int>(i);
        }
    }
    return targetIndex >= 0;
}

inline bool firstBallHitFrom(const std::vector<Ball2>& balls,
                             int ignoredIndex,
                             Vec2 origin,
                             Vec2 direction,
                             float radius,
                             float maximumTravel,
                             int& targetIndex,
                             float& cueCenterTravel) {
    targetIndex = -1;
    cueCenterTravel = std::numeric_limits<float>::infinity();
    direction = normalized(direction);
    if (lengthSquared(direction) < kEpsilon || radius <= 0.0f) return false;
    const float collisionRadius = 2.0f * radius;
    const float collisionRadius2 = collisionRadius * collisionRadius;
    for (std::size_t i = 0; i < balls.size(); ++i) {
        if (static_cast<int>(i) == ignoredIndex || !balls[i].active) continue;
        const Vec2 rel = balls[i].center - origin;
        const float projection = dot(rel, direction);
        if (projection <= kEpsilon) continue;
        const float perpendicular2 = std::max(0.0f, lengthSquared(rel) - projection * projection);
        if (perpendicular2 > collisionRadius2) continue;
        const float travel = projection - std::sqrt(std::max(0.0f, collisionRadius2 - perpendicular2));
        if (travel > kEpsilon && travel <= maximumTravel + kEpsilon && travel < cueCenterTravel) {
            cueCenterTravel = travel;
            targetIndex = static_cast<int>(i);
        }
    }
    return targetIndex >= 0;
}

inline Segment2 extendToRail(Vec2 start, Vec2 direction, const Bounds2& innerBounds) {
    const float distance = rayToInnerBounds(start, direction, innerBounds);
    if (distance <= kEpsilon) return {};
    const Vec2 unit = normalized(direction);
    return {start, start + unit * distance, true};
}

inline int clampedRailBounceCount(int value) {
    return std::max(kMinimumRailBounces, std::min(kMaximumRailBounces, value));
}

inline float clampedBounceAngleOffset(float degrees) {
    return std::max(-30.0f, std::min(30.0f, degrees));
}

inline float clampedRailInsetScale(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

inline float bounceAngleForOrdinal(float primaryDegrees,
                                   float secondaryDegrees,
                                   bool secondaryLinked,
                                   int bounceOrdinal) {
    if (bounceOrdinal <= 1 || secondaryLinked)
        return clampedBounceAngleOffset(primaryDegrees);
    return clampedBounceAngleOffset(secondaryDegrees);
}

inline Vec2 reflectedAtRail(Vec2 direction, Vec2 railPoint,
                            const Bounds2& innerBounds,
                            float bounceAngleOffsetDegrees = 0.0f) {
    direction = normalized(direction);
    const float tolerance = 1.0e-3f * std::max(innerBounds.max.x - innerBounds.min.x,
                                               innerBounds.max.y - innerBounds.min.y);
    const bool atMinimumX = std::fabs(railPoint.x - innerBounds.min.x) <= tolerance;
    const bool atMaximumX = std::fabs(railPoint.x - innerBounds.max.x) <= tolerance;
    const bool atMinimumY = std::fabs(railPoint.y - innerBounds.min.y) <= tolerance;
    const bool atMaximumY = std::fabs(railPoint.y - innerBounds.max.y) <= tolerance;
    const bool hitX = atMinimumX || atMaximumX;
    const bool hitY = atMinimumY || atMaximumY;

    Vec2 reflected = direction;
    if (hitX) reflected.x = -reflected.x;
    if (hitY) reflected.y = -reflected.y;
    reflected = normalized(reflected);

    const float offset = clampedBounceAngleOffset(bounceAngleOffsetDegrees);
    // Preserve the 0.1.8.8 result bit-for-bit at the default 0 degree setting.
    // Exact corner hits have two simultaneous normals, so keep the stable mirror
    // result there instead of introducing an arbitrary corner tangent.
    if (std::fabs(offset) <= kEpsilon || hitX == hitY) return reflected;

    Vec2 inwardNormal{};
    Vec2 tangent{};
    if (hitX) {
        inwardNormal = atMinimumX ? Vec2{1.0f, 0.0f} : Vec2{-1.0f, 0.0f};
        tangent = {0.0f, 1.0f};
    } else {
        inwardNormal = atMinimumY ? Vec2{0.0f, 1.0f} : Vec2{0.0f, -1.0f};
        tangent = {1.0f, 0.0f};
    }

    const float normalComponent = std::max(0.0f, dot(reflected, inwardNormal));
    const float tangentComponent = dot(reflected, tangent);
    const float baseAngle = std::atan2(std::fabs(tangentComponent), normalComponent);
    constexpr float kPi = 3.14159265358979323846f;
    const float minimumAngle = 1.0f * kPi / 180.0f;
    const float maximumAngle = 89.0f * kPi / 180.0f;
    const float adjustedAngle = std::max(
        minimumAngle,
        std::min(maximumAngle, baseAngle + offset * kPi / 180.0f));
    float tangentSign = tangentComponent < 0.0f ? -1.0f : 1.0f;
    if (std::fabs(tangentComponent) <= kEpsilon && dot(direction, tangent) < 0.0f)
        tangentSign = -1.0f;
    return normalized(inwardNormal * std::cos(adjustedAngle) +
                      tangent * (tangentSign * std::sin(adjustedAngle)));
}

inline Segment2 bounceFromRail(const Segment2& incoming, Vec2 incomingDirection,
                               const Bounds2& innerBounds,
                               float bounceAngleOffsetDegrees = 0.0f) {
    if (!incoming.valid) return {};
    const Vec2 reflected = reflectedAtRail(incomingDirection, incoming.b, innerBounds,
                                           bounceAngleOffsetDegrees);
    return extendToRail(incoming.b, reflected, innerBounds);
}

inline TrajectoryRoute buildRailRoute(Vec2 start, Vec2 direction,
                                      const Bounds2& innerBounds,
                                      int maximumRailBounces = 1,
                                      float bounceAngleOffsetDegrees = 0.0f,
                                      float secondaryBounceAngleOffsetDegrees = 0.0f,
                                      bool secondaryBounceAngleLinked = true) {
    TrajectoryRoute route;
    direction = normalized(direction);
    if (!innerBounds.valid() || !finite(start) ||
        lengthSquared(direction) < kEpsilon) return route;
    const int bounceCount = clampedRailBounceCount(maximumRailBounces);
    for (int leg = 0; leg <= bounceCount; ++leg) {
        Segment2 segment = extendToRail(start, direction, innerBounds);
        if (!segment.valid) break;
        route.segments[static_cast<std::size_t>(route.count++)] = segment;
        if (leg == bounceCount) break;
        const int bounceOrdinal = leg + 1;
        direction = reflectedAtRail(
            direction, segment.b, innerBounds,
            bounceAngleForOrdinal(bounceAngleOffsetDegrees,
                                  secondaryBounceAngleOffsetDegrees,
                                  secondaryBounceAngleLinked,
                                  bounceOrdinal));
        start = segment.b;
    }
    return route;
}

inline void syncLegacySegments(Prediction& prediction) {
    if (prediction.cueApproachRoute.count > 0)
        prediction.cueBefore = prediction.cueApproachRoute.segments[0];
    if (prediction.cueApproachRoute.count > 1)
        prediction.cueRailBounce = prediction.cueApproachRoute.segments[1];
    if (prediction.cueAfterRoute.count > 0)
        prediction.cueAfter = prediction.cueAfterRoute.segments[0];
    if (prediction.cueAfterRoute.count > 1)
        prediction.cueAfterRailBounce = prediction.cueAfterRoute.segments[1];
    if (prediction.targetRoute.count > 0)
        prediction.target = prediction.targetRoute.segments[0];
    if (prediction.targetRoute.count > 1)
        prediction.targetRailBounce = prediction.targetRoute.segments[1];
}

inline bool truncateSegmentAtCircles(Segment2& segment,
                                     const std::vector<Vec2>& centers,
                                     float radius) {
    if (!segment.valid || centers.empty() || radius <= kEpsilon) return false;
    const Vec2 delta = segment.b - segment.a;
    const float segmentLength = length(delta);
    if (segmentLength <= kEpsilon) return false;
    const Vec2 direction = delta * (1.0f / segmentLength);
    const float radiusSquared = radius * radius;
    float firstTravel = std::numeric_limits<float>::infinity();
    for (Vec2 center : centers) {
        const Vec2 relative = center - segment.a;
        const float projection = dot(relative, direction);
        const float perpendicularSquared = std::max(
            0.0f, lengthSquared(relative) - projection * projection);
        if (perpendicularSquared > radiusSquared) continue;
        const float halfChord = std::sqrt(
            std::max(0.0f, radiusSquared - perpendicularSquared));
        if (projection + halfChord < -kEpsilon) continue;
        const float entryTravel = std::max(0.0f, projection - halfChord);
        if (entryTravel <= segmentLength + kEpsilon)
            firstTravel = std::min(firstTravel, entryTravel);
    }
    if (!std::isfinite(firstTravel)) return false;
    segment.b = segment.a + direction * std::min(firstTravel, segmentLength);
    return true;
}

inline Prediction predictFromKnownImpact(const std::vector<Ball2>& balls,
                                         int cueIndex,
                                         int targetIndex,
                                         Vec2 cueAtImpact,
                                         float radius,
                                         Bounds2 tableBounds,
                                         float bounceAngleOffsetDegrees = 0.0f,
                                         int maximumRailBounces = 1,
                                         float secondaryBounceAngleOffsetDegrees = 0.0f,
                                         bool secondaryBounceAngleLinked = true,
                                         float railInsetScale = 1.0f) {
    Prediction result;
    if (cueIndex < 0 || targetIndex < 0 || cueIndex == targetIndex ||
        static_cast<std::size_t>(cueIndex) >= balls.size() ||
        static_cast<std::size_t>(targetIndex) >= balls.size() ||
        !balls[cueIndex].active || !balls[targetIndex].active ||
        radius <= 0.0f || !finite(cueAtImpact) || !tableBounds.valid()) {
        return result;
    }

    Bounds2 inner = tableBounds;
    const float railInset = radius * clampedRailInsetScale(railInsetScale);
    inner.min = inner.min + Vec2{railInset, railInset};
    inner.max = inner.max - Vec2{railInset, railInset};
    if (!inner.valid()) return result;

    const Vec2 cue = balls[cueIndex].center;
    const Vec2 impactDirection = normalized(cueAtImpact - cue);
    const Vec2 collisionNormal = normalized(balls[targetIndex].center - cueAtImpact);
    if (lengthSquared(impactDirection) < kEpsilon ||
        lengthSquared(collisionNormal) < kEpsilon) {
        return result;
    }

    result.targetIndex = targetIndex;
    result.cueTravelToTarget = length(cueAtImpact - cue);
    result.cueApproachRoute.segments[0] = {cue, cueAtImpact, true};
    result.cueApproachRoute.count = 1;
    result.targetRoute = buildRailRoute(balls[targetIndex].center, collisionNormal, inner,
                                        maximumRailBounces, bounceAngleOffsetDegrees,
                                        secondaryBounceAngleOffsetDegrees,
                                        secondaryBounceAngleLinked);

    const Vec2 cueResidual = impactDirection -
        collisionNormal * dot(impactDirection, collisionNormal);
    if (lengthSquared(cueResidual) > 1.0e-4f) {
        result.cueAfterRoute = buildRailRoute(cueAtImpact, cueResidual, inner,
                                              maximumRailBounces,
                                              bounceAngleOffsetDegrees,
                                              secondaryBounceAngleOffsetDegrees,
                                              secondaryBounceAngleLinked);
    }
    syncLegacySegments(result);
    return result;
}

inline Prediction predict(const std::vector<Ball2>& balls,
                          int cueIndex,
                          Vec2 aimDirection,
                          float radius,
                          Bounds2 tableBounds,
                          bool allowReverseDirection = true,
                          float bounceAngleOffsetDegrees = 0.0f,
                          int maximumRailBounces = 1,
                          float secondaryBounceAngleOffsetDegrees = 0.0f,
                          bool secondaryBounceAngleLinked = true,
                          float railInsetScale = 1.0f) {
    Prediction result;
    if (cueIndex < 0 || static_cast<std::size_t>(cueIndex) >= balls.size() ||
        !balls[cueIndex].active || radius <= 0.0f || !tableBounds.valid()) {
        return result;
    }

    Bounds2 inner = tableBounds;
    const float railInset = radius * clampedRailInsetScale(railInsetScale);
    inner.min = inner.min + Vec2{railInset, railInset};
    inner.max = inner.max - Vec2{railInset, railInset};
    if (!inner.valid()) return result;

    auto solveDirection = [&](Vec2 direction) {
        Prediction candidate;
        direction = normalized(direction);
        if (lengthSquared(direction) < kEpsilon) return candidate;

        int targetIndex = -1;
        const Vec2 cue = balls[cueIndex].center;
        Vec2 cueAtImpact{};
        Vec2 impactDirection = direction;
        Vec2 legStart = cue;
        Vec2 legDirection = direction;
        float accumulatedTravel = 0.0f;
        const int bounceCount = clampedRailBounceCount(maximumRailBounces);
        for (int leg = 0; leg <= bounceCount; ++leg) {
            const float railTravel = rayToInnerBounds(legStart, legDirection, inner);
            if (railTravel <= kEpsilon) break;
            float ballTravel = 0.0f;
            if (firstBallHitFrom(balls, cueIndex, legStart, legDirection, radius,
                                 railTravel, targetIndex, ballTravel)) {
                cueAtImpact = legStart + legDirection * ballTravel;
                candidate.cueApproachRoute.segments[
                    static_cast<std::size_t>(candidate.cueApproachRoute.count++)] =
                    {legStart, cueAtImpact, true};
                candidate.cueTravelToTarget = accumulatedTravel + ballTravel;
                impactDirection = legDirection;
                break;
            }

            const Vec2 railPoint = legStart + legDirection * railTravel;
            candidate.cueApproachRoute.segments[
                static_cast<std::size_t>(candidate.cueApproachRoute.count++)] =
                {legStart, railPoint, true};
            accumulatedTravel += railTravel;
            if (leg == bounceCount) break;
            const int bounceOrdinal = leg + 1;
            legDirection = reflectedAtRail(
                legDirection, railPoint, inner,
                bounceAngleForOrdinal(bounceAngleOffsetDegrees,
                                      secondaryBounceAngleOffsetDegrees,
                                      secondaryBounceAngleLinked,
                                      bounceOrdinal));
            legStart = railPoint;
        }

        if (targetIndex < 0) {
            syncLegacySegments(candidate);
            return candidate;
        }

        const Vec2 collisionNormal = normalized(balls[targetIndex].center - cueAtImpact);
        candidate.targetIndex = targetIndex;
        candidate.targetRoute = buildRailRoute(balls[targetIndex].center, collisionNormal,
                                               inner, maximumRailBounces,
                                               bounceAngleOffsetDegrees,
                                               secondaryBounceAngleOffsetDegrees,
                                               secondaryBounceAngleLinked);

        const Vec2 cueResidual = impactDirection - collisionNormal * dot(impactDirection, collisionNormal);
        if (lengthSquared(cueResidual) > 1.0e-4f) {
            candidate.cueAfterRoute = buildRailRoute(cueAtImpact, cueResidual, inner,
                                                     maximumRailBounces,
                                                     bounceAngleOffsetDegrees,
                                                     secondaryBounceAngleOffsetDegrees,
                                                     secondaryBounceAngleLinked);
        }
        syncLegacySegments(candidate);
        return candidate;
    };

    Prediction forward = solveDirection(aimDirection);
    if (!allowReverseDirection) return forward;
    Prediction reverse = solveDirection(aimDirection * -1.0f);
    if (forward.targetIndex >= 0 && reverse.targetIndex < 0) return forward;
    if (reverse.targetIndex >= 0 && forward.targetIndex < 0) return reverse;
    if (forward.targetIndex >= 0 && reverse.targetIndex >= 0) {
        return forward.cueTravelToTarget <= reverse.cueTravelToTarget ? forward : reverse;
    }
    return forward.cueBefore.valid ? forward : reverse;
}

}  // namespace poollab
