#include "ui_round_core.hpp"

#include <cmath>

namespace xiao_round {
namespace ui_round_core {
namespace {

constexpr double METERS_PER_MICRODEGREE_LAT = 0.11132;

double degreesToRadians(double degrees) {
  return degrees * 0.017453292519943295;
}

double approximateMetersBetween(int32_t latA, int32_t lonA, int32_t latB,
                                int32_t lonB) {
  const double midLatDegrees =
      (static_cast<double>(latA) + static_cast<double>(latB)) / 2000000.0;
  const double latMeters =
      static_cast<double>(latB - latA) * METERS_PER_MICRODEGREE_LAT;
  const double lonMeters = static_cast<double>(lonB - lonA) *
                           METERS_PER_MICRODEGREE_LAT *
                           std::cos(degreesToRadians(midLatDegrees));
  return std::sqrt((latMeters * latMeters) + (lonMeters * lonMeters));
}

} // namespace

TouchGesture classifyTouchGesture(uint32_t durationMs, int16_t deltaX,
                                  int16_t deltaY) {
  if (durationMs >= TOUCH_LONG_PRESS_MS) {
    return TouchGesture::LongPress;
  }

  const int16_t absX = deltaX < 0 ? -deltaX : deltaX;
  const int16_t absY = deltaY < 0 ? -deltaY : deltaY;
  if (absX >= TOUCH_SWIPE_MIN_PIXELS && absX >= absY) {
    return deltaX < 0 ? TouchGesture::SwipeLeft : TouchGesture::SwipeRight;
  }
  if (absY >= TOUCH_SWIPE_MIN_PIXELS) {
    return deltaY < 0 ? TouchGesture::SwipeUp : TouchGesture::SwipeDown;
  }
  return TouchGesture::TapCenter;
}

ManeuverIcon classifyManeuverIcon(uint8_t iconId) {
  switch (iconId) {
  case 2:
    return ManeuverIcon::Left;
  case 3:
    return ManeuverIcon::Right;
  case 4:
    return ManeuverIcon::UTurn;
  case 1:
  default:
    return ManeuverIcon::Straight;
  }
}

int16_t routeProgressPermille(uint32_t totalDistanceMeters,
                              bool hasRemainingDistance,
                              uint32_t remainingDistanceMeters) {
  if (!hasRemainingDistance || totalDistanceMeters == 0) {
    return -1;
  }
  if (remainingDistanceMeters >= totalDistanceMeters) {
    return 0;
  }
  const uint32_t completedMeters = totalDistanceMeters - remainingDistanceMeters;
  return static_cast<int16_t>(
      ((static_cast<uint64_t>(completedMeters) * 1000ULL) +
       (totalDistanceMeters / 2UL)) /
      totalDistanceMeters);
}

uint16_t speedKmhX10FromCmps(uint16_t speedCmps) {
  return static_cast<uint16_t>((static_cast<uint32_t>(speedCmps) * 36U + 50U) /
                               100U);
}

uint16_t speedKmhX10FromDelta(int32_t previousLatMicrodegrees,
                              int32_t previousLonMicrodegrees,
                              int32_t currentLatMicrodegrees,
                              int32_t currentLonMicrodegrees,
                              uint32_t deltaSeconds) {
  if (deltaSeconds == 0) {
    return 0;
  }
  const double meters = approximateMetersBetween(
      previousLatMicrodegrees, previousLonMicrodegrees, currentLatMicrodegrees,
      currentLonMicrodegrees);
  const double speedKmhX10 = (meters * 36.0) / deltaSeconds;
  if (speedKmhX10 >= 65535.0) {
    return 65535;
  }
  return static_cast<uint16_t>(speedKmhX10);
}

void rotateOffsetForHeading(double &eastMeters, double &northMeters,
                            uint16_t headingDegrees) {
  const double radians = degreesToRadians(headingDegrees);
  const double cosHeading = std::cos(radians);
  const double sinHeading = std::sin(radians);
  const double rotatedEast =
      (eastMeters * cosHeading) - (northMeters * sinHeading);
  const double rotatedNorth =
      (eastMeters * sinHeading) + (northMeters * cosHeading);
  eastMeters = rotatedEast;
  northMeters = rotatedNorth;
}

} // namespace ui_round_core
} // namespace xiao_round
