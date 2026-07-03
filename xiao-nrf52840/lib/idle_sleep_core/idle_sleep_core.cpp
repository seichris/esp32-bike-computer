#include "idle_sleep_core.hpp"

namespace xiao_round {
namespace idle_sleep_core {

bool activityFresh(uint32_t timestampMs, uint32_t nowMs) {
  return timestampMs != 0 && nowMs - timestampMs <= ACTIVE_PACKET_WINDOW_MS;
}

bool hasFreshBleTraffic(const BleActivityTimestamps &activity, uint32_t nowMs) {
  return activityFresh(activity.lastNavPacketMs, nowMs) ||
         activityFresh(activity.lastRoutePacketMs, nowMs) ||
         activityFresh(activity.lastRouteDuplicateMs, nowMs) ||
         activityFresh(activity.lastGpsPacketMs, nowMs) ||
         activityFresh(activity.lastSettingsPacketMs, nowMs) ||
         activityFresh(activity.lastAuthSuccessMs, nowMs) ||
         activityFresh(activity.lastConnectMs, nowMs) ||
         activityFresh(activity.lastDisconnectMs, nowMs);
}

uint16_t chooseIdleDelayMs(const IdleInputs &inputs) {
  if (inputs.settingsWritePending ||
      hasFreshBleTraffic(inputs.bleActivity, inputs.nowMs)) {
    return 0;
  }
  if (inputs.screenOff) {
    return SCREEN_OFF_IDLE_MS;
  }
  if (inputs.autoDimmed) {
    return DIMMED_IDLE_MS;
  }
  if (inputs.connected) {
    return CONNECTED_IDLE_MS;
  }
  return ACTIVE_NAV_IDLE_MS;
}

} // namespace idle_sleep_core
} // namespace xiao_round
