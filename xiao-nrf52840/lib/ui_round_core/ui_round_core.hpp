#pragma once

#include <cstdint>

namespace xiao_round {

enum class TouchGesture : uint8_t {
  TapCenter = 0,
  LongPress,
  SwipeLeft,
  SwipeRight,
  SwipeUp,
  SwipeDown,
};

enum class ManeuverIcon : uint8_t {
  Straight = 1,
  Left = 2,
  Right = 3,
  UTurn = 4,
};

namespace ui_round_core {

constexpr uint32_t TOUCH_LONG_PRESS_MS = 800;
constexpr int16_t TOUCH_SWIPE_MIN_PIXELS = 48;

TouchGesture classifyTouchGesture(uint32_t durationMs, int16_t deltaX,
                                  int16_t deltaY);
ManeuverIcon classifyManeuverIcon(uint8_t iconId);
int16_t routeProgressPermille(uint32_t totalDistanceMeters,
                              bool hasRemainingDistance,
                              uint32_t remainingDistanceMeters);
uint16_t speedKmhX10FromCmps(uint16_t speedCmps);
uint16_t speedKmhX10FromDelta(int32_t previousLatMicrodegrees,
                              int32_t previousLonMicrodegrees,
                              int32_t currentLatMicrodegrees,
                              int32_t currentLonMicrodegrees,
                              uint32_t deltaSeconds);
void rotateOffsetForHeading(double &eastMeters, double &northMeters,
                            uint16_t headingDegrees);

} // namespace ui_round_core
} // namespace xiao_round
