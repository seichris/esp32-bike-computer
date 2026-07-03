#include <unity.h>

#include "idle_sleep_core.hpp"

namespace {

void testActivityFreshUsesBoundedWindowAndIgnoresZeroTimestamp() {
  TEST_ASSERT_FALSE(xiao_round::idle_sleep_core::activityFresh(0, 5000));
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::activityFresh(3500, 5000));
  TEST_ASSERT_FALSE(xiao_round::idle_sleep_core::activityFresh(3499, 5000));
}

void testActivityFreshHandlesMillisWraparound() {
  TEST_ASSERT_TRUE(
      xiao_round::idle_sleep_core::activityFresh(0xFFFFFFF0UL, 20));
  TEST_ASSERT_FALSE(
      xiao_round::idle_sleep_core::activityFresh(0xFFFFF000UL, 20));
}

void testFreshBleTrafficCoversAllActivitySources() {
  xiao_round::idle_sleep_core::BleActivityTimestamps activity;
  const uint32_t now = 5000;

  activity.lastNavPacketMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastRoutePacketMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastRouteDuplicateMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastGpsPacketMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastSettingsPacketMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastAuthSuccessMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastConnectMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));

  activity = {};
  activity.lastDisconnectMs = 3500;
  TEST_ASSERT_TRUE(xiao_round::idle_sleep_core::hasFreshBleTraffic(activity, now));
}

void testPendingSettingsOrFreshBleTrafficSuppressesIdleDelay() {
  xiao_round::idle_sleep_core::IdleInputs inputs;
  inputs.nowMs = 5000;
  inputs.settingsWritePending = true;
  TEST_ASSERT_EQUAL_UINT16(0, xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));

  inputs.settingsWritePending = false;
  inputs.bleActivity.lastGpsPacketMs = 4500;
  TEST_ASSERT_EQUAL_UINT16(0, xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));
}

void testStaleBleTrafficDoesNotSuppressIdleDelay() {
  xiao_round::idle_sleep_core::IdleInputs inputs;
  inputs.nowMs = 5000;
  inputs.connected = true;
  inputs.bleActivity.lastGpsPacketMs = 3499;

  TEST_ASSERT_FALSE(
      xiao_round::idle_sleep_core::hasFreshBleTraffic(inputs.bleActivity,
                                                      inputs.nowMs));
  TEST_ASSERT_EQUAL_UINT16(
      xiao_round::idle_sleep_core::CONNECTED_IDLE_MS,
      xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));
}

void testIdleDelayPriorityMatchesPowerState() {
  xiao_round::idle_sleep_core::IdleInputs inputs;
  inputs.nowMs = 5000;
  TEST_ASSERT_EQUAL_UINT16(
      xiao_round::idle_sleep_core::ACTIVE_NAV_IDLE_MS,
      xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));

  inputs.connected = true;
  TEST_ASSERT_EQUAL_UINT16(
      xiao_round::idle_sleep_core::CONNECTED_IDLE_MS,
      xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));

  inputs.autoDimmed = true;
  TEST_ASSERT_EQUAL_UINT16(
      xiao_round::idle_sleep_core::DIMMED_IDLE_MS,
      xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));

  inputs.screenOff = true;
  TEST_ASSERT_EQUAL_UINT16(
      xiao_round::idle_sleep_core::SCREEN_OFF_IDLE_MS,
      xiao_round::idle_sleep_core::chooseIdleDelayMs(inputs));
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testActivityFreshUsesBoundedWindowAndIgnoresZeroTimestamp);
  RUN_TEST(testActivityFreshHandlesMillisWraparound);
  RUN_TEST(testFreshBleTrafficCoversAllActivitySources);
  RUN_TEST(testPendingSettingsOrFreshBleTrafficSuppressesIdleDelay);
  RUN_TEST(testStaleBleTrafficDoesNotSuppressIdleDelay);
  RUN_TEST(testIdleDelayPriorityMatchesPowerState);
  return UNITY_END();
}
