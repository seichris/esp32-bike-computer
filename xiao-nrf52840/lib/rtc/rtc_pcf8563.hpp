#pragma once

#include <Arduino.h>

namespace xiao_round::rtc {

enum class TimeSource : uint8_t {
  Unknown,
  RTC,
  BLE,
};

struct Status {
  bool initialized = false;
  bool present = false;
  bool timeValid = false;
  bool lastSyncOk = false;
  TimeSource source = TimeSource::Unknown;
  uint32_t unixTime = 0;
  uint32_t lastSyncMs = 0;
};

bool begin();
bool readUnixTime(uint32_t &unixTime);
bool syncFromUnixTime(uint32_t unixTime, const char *source);
const Status &status();
const char *sourceName(TimeSource source);

} // namespace xiao_round::rtc
