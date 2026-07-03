#pragma once

#include <Arduino.h>

#include "ble_navigation.hpp"
#include "idle_sleep.hpp"
#include "map_lite.hpp"
#include "power_manager.hpp"
#include "ui_round.hpp"

namespace xiao_round {

class Diagnostics {
public:
  void begin();
  void update(const BLENavigationServer &bleServer,
              const PowerManager &powerManager, const RoundUi &roundUi,
              const IdleSleepManager &idleSleepManager,
              const MapLite &mapLite);
  void logNow(const char *label, const BLENavigationServer &bleServer,
              const PowerManager &powerManager, const RoundUi &roundUi,
              const IdleSleepManager &idleSleepManager, const MapLite &mapLite);
  size_t approximateFreeHeapBytes() const;

private:
  void logSnapshot(const char *label, const BLENavigationServer &bleServer,
                   const PowerManager &powerManager, const RoundUi &roundUi,
                   const IdleSleepManager &idleSleepManager,
                   const MapLite &mapLite);
  void logResetReason() const;

  uint32_t lastLogMs = 0;
  uint32_t resetReason = 0;
  uint32_t bootloaderVersionValue = 0;
};

} // namespace xiao_round
