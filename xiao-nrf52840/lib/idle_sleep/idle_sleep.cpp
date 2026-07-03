#include "idle_sleep.hpp"

namespace xiao_round {
namespace {

constexpr uint16_t ACTIVE_NAV_IDLE_MS = 2;
constexpr uint16_t CONNECTED_IDLE_MS = 8;
constexpr uint16_t DIMMED_IDLE_MS = 15;
constexpr uint16_t SCREEN_OFF_IDLE_MS = 25;
constexpr uint32_t ACTIVE_PACKET_WINDOW_MS = 1500;

bool activityFresh(uint32_t timestampMs, uint32_t now) {
  return timestampMs != 0 && now - timestampMs <= ACTIVE_PACKET_WINDOW_MS;
}

bool hasFreshBleTraffic(const BLEDebugStats &stats, uint32_t now) {
  return activityFresh(stats.lastNavPacketMs, now) ||
         activityFresh(stats.lastRoutePacketMs, now) ||
         activityFresh(stats.lastGpsPacketMs, now) ||
         activityFresh(stats.lastSettingsPacketMs, now) ||
         activityFresh(stats.lastAuthSuccessMs, now) ||
         activityFresh(stats.lastConnectMs, now) ||
         activityFresh(stats.lastDisconnectMs, now);
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
  if (settingsWritePending || hasFreshBleTraffic(bleStats, now)) {
    return 0;
  }
  if (powerManager.isScreenOff()) {
    return SCREEN_OFF_IDLE_MS;
  }
  if (powerManager.isAutoDimmed()) {
    return DIMMED_IDLE_MS;
  }
  if (bleStats.connected) {
    return CONNECTED_IDLE_MS;
  }
  return ACTIVE_NAV_IDLE_MS;
}

} // namespace xiao_round
