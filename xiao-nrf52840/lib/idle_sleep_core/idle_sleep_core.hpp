#pragma once

#include <stdint.h>

namespace xiao_round {
namespace idle_sleep_core {

constexpr uint16_t ACTIVE_NAV_IDLE_MS = 2;
constexpr uint16_t CONNECTED_IDLE_MS = 8;
constexpr uint16_t DIMMED_IDLE_MS = 15;
constexpr uint16_t SCREEN_OFF_IDLE_MS = 25;
constexpr uint32_t ACTIVE_PACKET_WINDOW_MS = 1500;

struct BleActivityTimestamps {
  uint32_t lastNavPacketMs = 0;
  uint32_t lastRoutePacketMs = 0;
  uint32_t lastRouteDuplicateMs = 0;
  uint32_t lastGpsPacketMs = 0;
  uint32_t lastSettingsPacketMs = 0;
  uint32_t lastAuthSuccessMs = 0;
  uint32_t lastConnectMs = 0;
  uint32_t lastDisconnectMs = 0;
};

struct IdleInputs {
  bool settingsWritePending = false;
  bool connected = false;
  bool autoDimmed = false;
  bool screenOff = false;
  BleActivityTimestamps bleActivity;
  uint32_t nowMs = 0;
};

bool activityFresh(uint32_t timestampMs, uint32_t nowMs);
bool hasFreshBleTraffic(const BleActivityTimestamps &activity, uint32_t nowMs);
uint16_t chooseIdleDelayMs(const IdleInputs &inputs);

} // namespace idle_sleep_core
} // namespace xiao_round
