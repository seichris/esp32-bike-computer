#pragma once

#include <cstddef>
#include <cstdint>

namespace workout_telemetry_protocol {

constexpr std::size_t FRAME_SIZE = 16;
constexpr std::size_t FALLBACK_PREFIX_SIZE = 4;
constexpr std::size_t FALLBACK_FRAME_SIZE =
    FALLBACK_PREFIX_SIZE + FRAME_SIZE;
constexpr char FALLBACK_PREFIX[] = "WTLM";
constexpr uint8_t CAPABILITY_MASK = 1 << 7;
constexpr uint8_t KNOWN_SOURCE_FLAGS_MASK = 0x1F;
constexpr uint16_t UNAVAILABLE_UINT16 = UINT16_MAX;
constexpr uint32_t UNAVAILABLE_UINT32 = UINT32_MAX;
constexpr int16_t UNAVAILABLE_ALTITUDE = INT16_MIN;

enum class FrameKind : uint8_t {
  Core = 1,
  Extended = 2,
};

enum class SessionState : uint8_t {
  Idle = 0,
  Starting = 1,
  Running = 2,
  Paused = 3,
  Ending = 4,
  Ended = 5,
  Failed = 6,
};

constexpr uint16_t readUInt16LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint16_t>(bytes[offset]) |
         (static_cast<uint16_t>(bytes[offset + 1]) << 8);
}

constexpr uint32_t readUInt32LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

constexpr int16_t readInt16LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<int16_t>(readUInt16LE(bytes, offset));
}

} // namespace workout_telemetry_protocol
