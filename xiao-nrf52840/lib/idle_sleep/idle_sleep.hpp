#pragma once

#include <Arduino.h>

#include "ble_navigation.hpp"
#include "power_manager.hpp"

namespace xiao_round {

struct IdleSleepStats {
  uint32_t idleCallCount = 0;
  uint32_t totalIdleMs = 0;
  uint16_t lastIdleMs = 0;
  uint16_t maxIdleMs = 0;
  bool lastScreenOff = false;
  bool lastConnected = false;
};

class IdleSleepManager {
public:
  void update(const BLENavigationServer &bleServer,
              const PowerManager &powerManager, bool settingsWritePending);
  const IdleSleepStats &stats() const { return sleepStats; }

private:
  uint16_t chooseIdleDelayMs(const BLEDebugStats &bleStats,
                             const PowerManager &powerManager,
                             bool settingsWritePending,
                             uint32_t now) const;

  IdleSleepStats sleepStats;
};

} // namespace xiao_round
