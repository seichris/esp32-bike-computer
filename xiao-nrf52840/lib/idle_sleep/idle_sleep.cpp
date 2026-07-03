#include "idle_sleep.hpp"

#include "idle_sleep_core.hpp"

namespace xiao_round {
namespace {

idle_sleep_core::BleActivityTimestamps bleActivityFromStats(
    const BLEDebugStats &stats) {
  idle_sleep_core::BleActivityTimestamps activity;
  activity.lastNavPacketMs = stats.lastNavPacketMs;
  activity.lastRoutePacketMs = stats.lastRoutePacketMs;
  activity.lastRouteDuplicateMs = stats.lastRouteDuplicateMs;
  activity.lastGpsPacketMs = stats.lastGpsPacketMs;
  activity.lastSettingsPacketMs = stats.lastSettingsPacketMs;
  activity.lastAuthSuccessMs = stats.lastAuthSuccessMs;
  activity.lastConnectMs = stats.lastConnectMs;
  activity.lastDisconnectMs = stats.lastDisconnectMs;
  return activity;
}

} // namespace

void IdleSleepManager::update(const BLENavigationServer &bleServer,
                              const PowerManager &powerManager,
                              bool settingsWritePending) {
  const uint32_t now = millis();
  const BLEDebugStats bleStats = bleServer.getDebugStats();
  const uint16_t idleMs =
      chooseIdleDelayMs(bleStats, powerManager, settingsWritePending, now);
  if (idleMs == 0) {
    return;
  }

  delay(idleMs);
  sleepStats.idleCallCount++;
  sleepStats.totalIdleMs += idleMs;
  sleepStats.lastIdleMs = idleMs;
  sleepStats.lastScreenOff = powerManager.isScreenOff();
  sleepStats.lastConnected = bleStats.connected;
  if (idleMs > sleepStats.maxIdleMs) {
    sleepStats.maxIdleMs = idleMs;
  }
}

uint16_t IdleSleepManager::chooseIdleDelayMs(const BLEDebugStats &bleStats,
                                             const PowerManager &powerManager,
                                             bool settingsWritePending,
                                             uint32_t now) const {
  idle_sleep_core::IdleInputs inputs;
  inputs.settingsWritePending = settingsWritePending;
  inputs.connected = bleStats.connected;
  inputs.autoDimmed = powerManager.isAutoDimmed();
  inputs.screenOff = powerManager.isScreenOff();
  inputs.bleActivity = bleActivityFromStats(bleStats);
  inputs.nowMs = now;
  return idle_sleep_core::chooseIdleDelayMs(inputs);
}

} // namespace xiao_round
