#pragma once

#include <stdint.h>

namespace xiao_round {
namespace rtc_core {

constexpr uint32_t MIN_VALID_UNIX_TIME = 1704067200UL; // 2024-01-01T00:00:00Z
constexpr uint32_t MAX_VALID_UNIX_TIME = 4102444800UL; // 2100-01-01T00:00:00Z
constexpr uint8_t SECONDS_VL_BIT = 0x80;

enum class TimeSource : uint8_t {
  Unknown,
  RTC,
  BLE,
};

struct CivilTime {
  uint16_t year = 0;
  uint8_t month = 0;
  uint8_t day = 0;
  uint8_t hour = 0;
  uint8_t minute = 0;
  uint8_t second = 0;
  uint8_t weekday = 0;
};

bool isLeapYear(uint16_t year);
uint8_t daysInMonth(uint16_t year, uint8_t month);
bool civilFromUnixTime(uint32_t unixTime, CivilTime &out);
bool unixTimeFromCivil(const CivilTime &time, uint32_t &unixTime);
bool decodeRtcRegisters(const uint8_t *regs, uint32_t &unixTime);
bool encodeRtcRegisters(const CivilTime &time, uint8_t *regs);
const char *sourceName(TimeSource source);

} // namespace rtc_core
} // namespace xiao_round
