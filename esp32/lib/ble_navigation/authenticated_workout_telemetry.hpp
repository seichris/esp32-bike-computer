#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>

namespace workout_telemetry_transport {

// Keep the native characteristic's unwrap-to-handler glue host-testable. The
// caller supplies the ownership-aware unwrap operation so production can keep
// its BLE mutex and session-divergence handling in one place.
template <typename Unwrap, typename Handle>
bool dispatchAuthenticatedNativeFrame(const std::string &frame,
                                      Unwrap &&unwrap, Handle &&handle) {
  std::string payload;
  if (!std::forward<Unwrap>(unwrap)(frame, payload)) {
    return false;
  }
  std::forward<Handle>(handle)(
      reinterpret_cast<const uint8_t *>(payload.data()), payload.size());
  return true;
}

} // namespace workout_telemetry_transport
