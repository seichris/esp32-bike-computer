#include <unity.h>

#include "ui_round_core.hpp"

#include <cmath>

namespace {

void assertNear(double expected, double actual) {
  const long expectedScaled = lround(expected * 1000.0);
  const long actualScaled = lround(actual * 1000.0);
  TEST_ASSERT_INT_WITHIN(1, expectedScaled, actualScaled);
}

void testTouchClassificationKeepsSmallMovementAsTap() {
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::TapCenter,
      xiao_round::ui_round_core::classifyTouchGesture(120, 47, 47));
}

void testTouchClassificationLongPressWinsOverMovement() {
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::LongPress,
      xiao_round::ui_round_core::classifyTouchGesture(
          xiao_round::ui_round_core::TOUCH_LONG_PRESS_MS, -120, 0));
}

void testTouchClassificationHorizontalSwipes() {
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::SwipeLeft,
      xiao_round::ui_round_core::classifyTouchGesture(
          200, -xiao_round::ui_round_core::TOUCH_SWIPE_MIN_PIXELS, 8));
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::SwipeRight,
      xiao_round::ui_round_core::classifyTouchGesture(200, 90, 90));
}

void testTouchClassificationVerticalSwipes() {
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::SwipeUp,
      xiao_round::ui_round_core::classifyTouchGesture(200, 12, -72));
  TEST_ASSERT_EQUAL(
      xiao_round::TouchGesture::SwipeDown,
      xiao_round::ui_round_core::classifyTouchGesture(
          200, 0, xiao_round::ui_round_core::TOUCH_SWIPE_MIN_PIXELS));
}

void testManeuverIconClassificationMatchesIosContract() {
  TEST_ASSERT_EQUAL(xiao_round::ManeuverIcon::Straight,
                    xiao_round::ui_round_core::classifyManeuverIcon(1));
  TEST_ASSERT_EQUAL(xiao_round::ManeuverIcon::Left,
                    xiao_round::ui_round_core::classifyManeuverIcon(2));
  TEST_ASSERT_EQUAL(xiao_round::ManeuverIcon::Right,
                    xiao_round::ui_round_core::classifyManeuverIcon(3));
  TEST_ASSERT_EQUAL(xiao_round::ManeuverIcon::UTurn,
                    xiao_round::ui_round_core::classifyManeuverIcon(4));
  TEST_ASSERT_EQUAL(xiao_round::ManeuverIcon::Straight,
                    xiao_round::ui_round_core::classifyManeuverIcon(255));
}

void testRouteProgressPermilleClampsAndRounds() {
  TEST_ASSERT_EQUAL_INT16(
      -1, xiao_round::ui_round_core::routeProgressPermille(0, true, 0));
  TEST_ASSERT_EQUAL_INT16(
      -1, xiao_round::ui_round_core::routeProgressPermille(1000, false, 500));
  TEST_ASSERT_EQUAL_INT16(
      0, xiao_round::ui_round_core::routeProgressPermille(1000, true, 1200));
  TEST_ASSERT_EQUAL_INT16(
      500, xiao_round::ui_round_core::routeProgressPermille(1000, true, 500));
  TEST_ASSERT_EQUAL_INT16(
      1000, xiao_round::ui_round_core::routeProgressPermille(1000, true, 0));
}

void testSpeedConversionFromCentimetersPerSecond() {
  TEST_ASSERT_EQUAL_UINT16(0, xiao_round::ui_round_core::speedKmhX10FromCmps(0));
  TEST_ASSERT_EQUAL_UINT16(234,
                           xiao_round::ui_round_core::speedKmhX10FromCmps(650));
}

void testSpeedFallbackFromGpsDelta() {
  TEST_ASSERT_EQUAL_UINT16(
      400,
      xiao_round::ui_round_core::speedKmhX10FromDelta(0, 0, 1000, 0, 10));
}

void testSpeedFallbackRejectsZeroDeltaAndSaturatesExtremeJumps() {
  TEST_ASSERT_EQUAL_UINT16(
      0, xiao_round::ui_round_core::speedKmhX10FromDelta(0, 0, 1000, 0, 0));
  TEST_ASSERT_EQUAL_UINT16(
      65535,
      xiao_round::ui_round_core::speedKmhX10FromDelta(0, 0, 20000000, 0, 1));
}

void testCourseUpRotationForEastHeading() {
  double eastMeters = 100.0;
  double northMeters = 0.0;
  xiao_round::ui_round_core::rotateOffsetForHeading(eastMeters, northMeters,
                                                    90);
  assertNear(0.0, eastMeters);
  assertNear(100.0, northMeters);
}

void testCourseUpRotationForNorthPointWhenHeadingEast() {
  double eastMeters = 0.0;
  double northMeters = 100.0;
  xiao_round::ui_round_core::rotateOffsetForHeading(eastMeters, northMeters,
                                                    90);
  assertNear(-100.0, eastMeters);
  assertNear(0.0, northMeters);
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testTouchClassificationKeepsSmallMovementAsTap);
  RUN_TEST(testTouchClassificationLongPressWinsOverMovement);
  RUN_TEST(testTouchClassificationHorizontalSwipes);
  RUN_TEST(testTouchClassificationVerticalSwipes);
  RUN_TEST(testManeuverIconClassificationMatchesIosContract);
  RUN_TEST(testRouteProgressPermilleClampsAndRounds);
  RUN_TEST(testSpeedConversionFromCentimetersPerSecond);
  RUN_TEST(testSpeedFallbackFromGpsDelta);
  RUN_TEST(testSpeedFallbackRejectsZeroDeltaAndSaturatesExtremeJumps);
  RUN_TEST(testCourseUpRotationForEastHeading);
  RUN_TEST(testCourseUpRotationForNorthPointWhenHeadingEast);
  return UNITY_END();
}
