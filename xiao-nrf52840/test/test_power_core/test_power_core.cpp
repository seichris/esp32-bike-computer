#include <unity.h>

#include "power_core.hpp"

namespace {

void testTargetBrightnessClampKeepsUsableBacklightRange() {
  TEST_ASSERT_EQUAL_UINT8(5, xiao_round::power_core::clampTargetBrightness(0));
  TEST_ASSERT_EQUAL_UINT8(5, xiao_round::power_core::clampTargetBrightness(4));
  TEST_ASSERT_EQUAL_UINT8(80, xiao_round::power_core::clampTargetBrightness(80));
  TEST_ASSERT_EQUAL_UINT8(100,
                          xiao_round::power_core::clampTargetBrightness(140));
}

void testOutputBrightnessAllowsScreenOffButClampsHighValues() {
  TEST_ASSERT_EQUAL_UINT8(0, xiao_round::power_core::clampOutputBrightness(0));
  TEST_ASSERT_EQUAL_UINT8(20, xiao_round::power_core::clampOutputBrightness(20));
  TEST_ASSERT_EQUAL_UINT8(100,
                          xiao_round::power_core::clampOutputBrightness(255));
}

void testBatteryPercentClampsAndInterpolates() {
  TEST_ASSERT_EQUAL_UINT8(0, xiao_round::power_core::estimateBatteryPercent(3200));
  TEST_ASSERT_EQUAL_UINT8(0, xiao_round::power_core::estimateBatteryPercent(3300));
  TEST_ASSERT_EQUAL_UINT8(50,
                          xiao_round::power_core::estimateBatteryPercent(3750));
  TEST_ASSERT_EQUAL_UINT8(100,
                          xiao_round::power_core::estimateBatteryPercent(4200));
  TEST_ASSERT_EQUAL_UINT8(100,
                          xiao_round::power_core::estimateBatteryPercent(4300));
}

void testBatteryScaleClampsToSupportedDividerRange() {
  TEST_ASSERT_EQUAL_UINT16(1000, xiao_round::power_core::clampBatteryScale(100));
  TEST_ASSERT_EQUAL_UINT16(2000, xiao_round::power_core::clampBatteryScale(2000));
  TEST_ASSERT_EQUAL_UINT16(4000, xiao_round::power_core::clampBatteryScale(5000));
}

void testBatteryMillivoltsUsesClampedScale() {
  TEST_ASSERT_EQUAL_UINT16(
      4100, xiao_round::power_core::batteryMillivoltsFromPin(2050, 2000));
  TEST_ASSERT_EQUAL_UINT16(
      1000, xiao_round::power_core::batteryMillivoltsFromPin(1000, 10));
  TEST_ASSERT_EQUAL_UINT16(
      4000, xiao_round::power_core::batteryMillivoltsFromPin(1000, 5000));
  TEST_ASSERT_EQUAL_UINT16(
      UINT16_MAX,
      xiao_round::power_core::batteryMillivoltsFromPin(UINT16_MAX, 4000));
}

void testCalibrationScaleRoundsAndRejectsInvalidInputs() {
  uint16_t scale = 0;
  TEST_ASSERT_TRUE(
      xiao_round::power_core::computeCalibrationScale(4100, 2050, scale));
  TEST_ASSERT_EQUAL_UINT16(2000, scale);

  TEST_ASSERT_TRUE(
      xiao_round::power_core::computeCalibrationScale(4101, 2050, scale));
  TEST_ASSERT_EQUAL_UINT16(2000, scale);

  TEST_ASSERT_FALSE(
      xiao_round::power_core::computeCalibrationScale(2499, 2050, scale));
  TEST_ASSERT_FALSE(
      xiao_round::power_core::computeCalibrationScale(4501, 2050, scale));
  TEST_ASSERT_FALSE(
      xiao_round::power_core::computeCalibrationScale(4100, 0, scale));
}

void testCalibrationScaleSaturatesExtremeDividerResults() {
  uint16_t scale = 0;
  TEST_ASSERT_TRUE(
      xiao_round::power_core::computeCalibrationScale(2500, 3000, scale));
  TEST_ASSERT_EQUAL_UINT16(1000, scale);

  TEST_ASSERT_TRUE(
      xiao_round::power_core::computeCalibrationScale(4500, 500, scale));
  TEST_ASSERT_EQUAL_UINT16(4000, scale);
}

void testLatestActivityUsesAllBleAndLocalSources() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 100;
  activity.userActivityMs = 200;
  activity.brightnessChangeMs = 300;
  activity.bleConnectMs = 400;
  activity.bleDisconnectMs = 500;
  activity.bleAuthSuccessMs = 600;
  activity.bleNavPacketMs = 700;
  activity.bleRoutePacketMs = 800;
  activity.bleRouteDuplicateMs = 900;
  activity.bleGpsPacketMs = 1000;
  activity.bleSettingsPacketMs = 1100;
  activity.bleDeviceCommandMs = 1200;

  TEST_ASSERT_EQUAL_UINT32(1200, xiao_round::power_core::latestActivityMs(activity));
}

void testLatestActivityPinsDisconnectDuplicateAndCommandSources() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 100;
  activity.bleDisconnectMs = 700;
  TEST_ASSERT_EQUAL_UINT32(700, xiao_round::power_core::latestActivityMs(activity));

  activity.bleRouteDuplicateMs = 800;
  TEST_ASSERT_EQUAL_UINT32(800, xiao_round::power_core::latestActivityMs(activity));

  activity.bleDeviceCommandMs = 900;
  TEST_ASSERT_EQUAL_UINT32(900, xiao_round::power_core::latestActivityMs(activity));
}

void testBrightnessDecisionKeepsTargetBeforeAutoDim() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 1000;
  const xiao_round::power_core::BrightnessDecision decision =
      xiao_round::power_core::chooseBrightness(80, true, activity, 30999);

  TEST_ASSERT_EQUAL_UINT8(80, decision.outputBrightnessPercent);
  TEST_ASSERT_FALSE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);
}

void testBrightnessDecisionDimsButDoesNotScreenOffWhileConnected() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 1000;
  xiao_round::power_core::BrightnessDecision decision =
      xiao_round::power_core::chooseBrightness(80, true, activity, 31000);

  TEST_ASSERT_EQUAL_UINT8(20, decision.outputBrightnessPercent);
  TEST_ASSERT_TRUE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);

  decision = xiao_round::power_core::chooseBrightness(10, true, activity, 31000);
  TEST_ASSERT_EQUAL_UINT8(10, decision.outputBrightnessPercent);
  TEST_ASSERT_FALSE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);

  decision = xiao_round::power_core::chooseBrightness(80, true, activity, 121000);
  TEST_ASSERT_EQUAL_UINT8(20, decision.outputBrightnessPercent);
  TEST_ASSERT_TRUE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);
}

void testBrightnessDecisionUsesBrightnessChangeAsActivity() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 1000;
  activity.brightnessChangeMs = 50000;

  const xiao_round::power_core::BrightnessDecision decision =
      xiao_round::power_core::chooseBrightness(80, false, activity, 79999);

  TEST_ASSERT_EQUAL_UINT8(80, decision.outputBrightnessPercent);
  TEST_ASSERT_FALSE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);
}

void testBrightnessDecisionSurvivesMillisWrap() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 1000;
  activity.bleNavPacketMs = UINT32_MAX - 999U;

  const xiao_round::power_core::BrightnessDecision decision =
      xiao_round::power_core::chooseBrightness(80, false, activity, 1000);

  TEST_ASSERT_EQUAL_UINT8(80, decision.outputBrightnessPercent);
  TEST_ASSERT_FALSE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);
}

void testBrightnessDecisionScreenOffStartsAfterDisconnectActivity() {
  xiao_round::power_core::ActivityTimestamps activity;
  activity.bootActivityMs = 1;
  activity.bleNavPacketMs = 1000;
  activity.bleDisconnectMs = 50000;

  xiao_round::power_core::BrightnessDecision decision =
      xiao_round::power_core::chooseBrightness(80, false, activity, 169999);
  TEST_ASSERT_EQUAL_UINT8(20, decision.outputBrightnessPercent);
  TEST_ASSERT_TRUE(decision.autoDimmed);
  TEST_ASSERT_FALSE(decision.screenOff);

  decision = xiao_round::power_core::chooseBrightness(80, false, activity, 170000);
  TEST_ASSERT_EQUAL_UINT8(0, decision.outputBrightnessPercent);
  TEST_ASSERT_TRUE(decision.autoDimmed);
  TEST_ASSERT_TRUE(decision.screenOff);
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testTargetBrightnessClampKeepsUsableBacklightRange);
  RUN_TEST(testOutputBrightnessAllowsScreenOffButClampsHighValues);
  RUN_TEST(testBatteryPercentClampsAndInterpolates);
  RUN_TEST(testBatteryScaleClampsToSupportedDividerRange);
  RUN_TEST(testBatteryMillivoltsUsesClampedScale);
  RUN_TEST(testCalibrationScaleRoundsAndRejectsInvalidInputs);
  RUN_TEST(testCalibrationScaleSaturatesExtremeDividerResults);
  RUN_TEST(testLatestActivityUsesAllBleAndLocalSources);
  RUN_TEST(testLatestActivityPinsDisconnectDuplicateAndCommandSources);
  RUN_TEST(testBrightnessDecisionKeepsTargetBeforeAutoDim);
  RUN_TEST(testBrightnessDecisionDimsButDoesNotScreenOffWhileConnected);
  RUN_TEST(testBrightnessDecisionUsesBrightnessChangeAsActivity);
  RUN_TEST(testBrightnessDecisionSurvivesMillisWrap);
  RUN_TEST(testBrightnessDecisionScreenOffStartsAfterDisconnectActivity);
  return UNITY_END();
}
