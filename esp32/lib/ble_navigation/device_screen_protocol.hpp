#pragma once

#include <cstdint>

namespace device_screen_protocol {

constexpr int32_t CURRENT_MASK_MARKER = 1 << 30;
constexpr int32_t BATTERY_STATUS_BIT = 1 << 4;

inline int32_t applyCompatibility(int32_t incomingMask,
                                  uint8_t currentMask) {
  const bool isCurrentMask = (incomingMask & CURRENT_MASK_MARKER) != 0;
  int32_t appliedMask = incomingMask & ~CURRENT_MASK_MARKER;
  if (!isCurrentMask) {
    appliedMask = (appliedMask & ~BATTERY_STATUS_BIT) |
                  (currentMask & BATTERY_STATUS_BIT);
  }
  return appliedMask;
}

} // namespace device_screen_protocol
