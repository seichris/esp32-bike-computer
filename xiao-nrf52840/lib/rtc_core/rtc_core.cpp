#include "rtc_core.hpp"

namespace xiao_round {
namespace rtc_core {
namespace {

uint8_t decToBcd(uint8_t value) {
  return static_cast<uint8_t>(((value / 10U) << 4) | (value % 10U));
}

bool decodeBcd(uint8_t value, uint8_t &decoded) {
  const uint8_t high = value >> 4;
  const uint8_t low = value & 0x0F;
  if (high > 9 || low > 9) {
    return false;
  }
  decoded = static_cast<uint8_t>(high * 10U + low);
  return true;
}

int32_t daysFromCivil(int32_t year, uint8_t month, uint8_t day) {
  year -= month <= 2;
  const int32_t era = (year >= 0 ? year : year - 399) / 400;
  const uint32_t yoe = static_cast<uint32_t>(year - era * 400);
  const uint32_t doy =
      (153U * (month + (month > 2 ? -3 : 9)) + 2U) / 5U + day - 1U;
  const uint32_t doe = yoe * 365U + yoe / 4U - yoe / 100U + doy;
  return era * 146097 + static_cast<int32_t>(doe) - 719468;
}

bool isValidCivilTime(const CivilTime &time) {
  if (time.year < 2024 || time.year >= 2100 || time.month < 1 ||
      time.month > 12 || time.day < 1 || time.hour > 23 ||
      time.minute > 59 || time.second > 59 || time.weekday > 6) {
    return false;
  }
  return time.day <= daysInMonth(time.year, time.month);
}

} // namespace

bool isLeapYear(uint16_t year) {
  return ((year % 4U == 0U) && (year % 100U != 0U)) || (year % 400U == 0U);
}

uint8_t daysInMonth(uint16_t year, uint8_t month) {
  static const uint8_t days[] = {31, 28, 31, 30, 31, 30,
                                 31, 31, 30, 31, 30, 31};
  if (month < 1 || month > 12) {
    return 0;
  }
  if (month == 2 && isLeapYear(year)) {
    return 29;
  }
  return days[month - 1];
}

bool civilFromUnixTime(uint32_t unixTime, CivilTime &out) {
  if (unixTime < MIN_VALID_UNIX_TIME || unixTime >= MAX_VALID_UNIX_TIME) {
    return false;
  }

  uint32_t days = unixTime / 86400UL;
  uint32_t secondsOfDay = unixTime % 86400UL;
  out.hour = static_cast<uint8_t>(secondsOfDay / 3600UL);
  secondsOfDay %= 3600UL;
  out.minute = static_cast<uint8_t>(secondsOfDay / 60UL);
  out.second = static_cast<uint8_t>(secondsOfDay % 60UL);
  out.weekday = static_cast<uint8_t>((days + 4U) % 7U);

  uint16_t year = 1970;
  while (true) {
    const uint16_t yearDays = isLeapYear(year) ? 366 : 365;
    if (days < yearDays) {
      break;
    }
    days -= yearDays;
    year++;
  }

  uint8_t month = 1;
  while (month <= 12) {
    const uint8_t monthDays = daysInMonth(year, month);
    if (days < monthDays) {
      break;
    }
    days -= monthDays;
    month++;
  }

  out.year = year;
  out.month = month;
  out.day = static_cast<uint8_t>(days + 1U);
  return isValidCivilTime(out);
}

bool unixTimeFromCivil(const CivilTime &time, uint32_t &unixTime) {
  if (!isValidCivilTime(time)) {
    return false;
  }

  const int32_t days = daysFromCivil(time.year, time.month, time.day);
  const uint64_t seconds =
      static_cast<uint64_t>(days) * 86400ULL +
      static_cast<uint64_t>(time.hour) * 3600ULL +
      static_cast<uint64_t>(time.minute) * 60ULL + time.second;
  if (seconds < MIN_VALID_UNIX_TIME || seconds >= MAX_VALID_UNIX_TIME) {
    return false;
  }

  unixTime = static_cast<uint32_t>(seconds);
  return true;
}

bool decodeRtcRegisters(const uint8_t *regs, uint32_t &unixTime) {
  if (regs == nullptr || (regs[0] & SECONDS_VL_BIT)) {
    return false;
  }

  uint8_t year = 0;
  CivilTime time;
  if (!decodeBcd(regs[0] & 0x7F, time.second) ||
      !decodeBcd(regs[1] & 0x7F, time.minute) ||
      !decodeBcd(regs[2] & 0x3F, time.hour) ||
      !decodeBcd(regs[3] & 0x3F, time.day) ||
      !decodeBcd(regs[4] & 0x07, time.weekday) ||
      !decodeBcd(regs[5] & 0x1F, time.month) ||
      !decodeBcd(regs[6], year)) {
    return false;
  }

  time.year = static_cast<uint16_t>(2000U + year);
  return unixTimeFromCivil(time, unixTime);
}

bool encodeRtcRegisters(const CivilTime &time, uint8_t *regs) {
  if (regs == nullptr || !isValidCivilTime(time)) {
    return false;
  }

  regs[0] = decToBcd(time.second);
  regs[1] = decToBcd(time.minute);
  regs[2] = decToBcd(time.hour);
  regs[3] = decToBcd(time.day);
  regs[4] = decToBcd(time.weekday);
  regs[5] = decToBcd(time.month);
  regs[6] = decToBcd(static_cast<uint8_t>(time.year - 2000U));
  return true;
}

const char *sourceName(TimeSource source) {
  switch (source) {
  case TimeSource::RTC:
    return "rtc";
  case TimeSource::BLE:
    return "ble";
  case TimeSource::Unknown:
  default:
    return "unknown";
  }
}

} // namespace rtc_core
} // namespace xiao_round
