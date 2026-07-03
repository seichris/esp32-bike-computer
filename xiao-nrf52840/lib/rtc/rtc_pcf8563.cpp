#include "rtc_pcf8563.hpp"

#include "round_display_pins.hpp"

#include <Wire.h>
#include <stdlib.h>

namespace xiao_round::rtc {
namespace {

constexpr uint8_t RTC_ADDR = 0x51;
constexpr uint8_t REG_CONTROL_1 = 0x00;
constexpr uint8_t REG_SECONDS_PCF8563 = 0x02;
constexpr uint8_t REG_SECONDS_PCF85063 = 0x04;
constexpr uint8_t CONTROL_1_STOP_BIT = 0x20;
constexpr uint8_t CONTROL_1_EXT_TEST_BIT = 0x80;
constexpr uint8_t SECONDS_VL_BIT = 0x80;
constexpr uint32_t MIN_VALID_UNIX_TIME = 1704067200UL; // 2024-01-01T00:00:00Z
constexpr uint32_t MAX_VALID_UNIX_TIME = 4102444800UL; // 2100-01-01T00:00:00Z

Status rtcStatus;
uint8_t timeRegisterBase = REG_SECONDS_PCF8563;

struct CivilTime {
  uint16_t year = 0;
  uint8_t month = 0;
  uint8_t day = 0;
  uint8_t hour = 0;
  uint8_t minute = 0;
  uint8_t second = 0;
  uint8_t weekday = 0;
};

uint8_t bcdToDec(uint8_t value) {
  return static_cast<uint8_t>(((value >> 4) * 10U) + (value & 0x0F));
}

uint8_t decToBcd(uint8_t value) {
  return static_cast<uint8_t>(((value / 10U) << 4) | (value % 10U));
}

bool isLeapYear(uint16_t year) {
  return ((year % 4U == 0U) && (year % 100U != 0U)) || (year % 400U == 0U);
}

uint8_t daysInMonth(uint16_t year, uint8_t month) {
  static const uint8_t days[] = {31, 28, 31, 30, 31, 30,
                                 31, 31, 30, 31, 30, 31};
  if (month == 2 && isLeapYear(year)) {
    return 29;
  }
  return days[month - 1];
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
  return year >= 2024 && year < 2100;
}

bool unixTimeFromCivil(const CivilTime &time, uint32_t &unixTime) {
  if (time.year < 2024 || time.year >= 2100 || time.month < 1 ||
      time.month > 12 || time.day < 1 ||
      time.day > daysInMonth(time.year, time.month) || time.hour > 23 ||
      time.minute > 59 || time.second > 59) {
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

bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(RTC_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool readRegister(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(RTC_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(RTC_ADDR, static_cast<uint8_t>(1)) != 1) {
    return false;
  }
  value = Wire.read();
  return true;
}

bool readRegisterBlock(uint8_t reg, uint8_t *buffer, uint8_t len) {
  if (buffer == nullptr || len == 0) {
    return false;
  }
  Wire.beginTransmission(RTC_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(RTC_ADDR, len) != len) {
    return false;
  }
  for (uint8_t i = 0; i < len; i++) {
    buffer[i] = Wire.read();
  }
  return true;
}

bool writeRegisterBlock(uint8_t reg, const uint8_t *buffer, uint8_t len) {
  if (buffer == nullptr || len == 0) {
    return false;
  }
  Wire.beginTransmission(RTC_ADDR);
  Wire.write(reg);
  for (uint8_t i = 0; i < len; i++) {
    Wire.write(buffer[i]);
  }
  return Wire.endTransmission() == 0;
}

bool probeRtc() {
  Wire.beginTransmission(RTC_ADDR);
  return Wire.endTransmission() == 0;
}

bool setStopBit(bool stopped) {
  uint8_t control1 = 0;
  if (!readRegister(REG_CONTROL_1, control1)) {
    return false;
  }

  uint8_t next = control1 & ~CONTROL_1_EXT_TEST_BIT;
  if (stopped) {
    next |= CONTROL_1_STOP_BIT;
  } else {
    next &= ~CONTROL_1_STOP_BIT;
  }

  if (next == control1) {
    return true;
  }
  return writeRegister(REG_CONTROL_1, next);
}

bool decodeRtcRegisters(const uint8_t regs[7], uint32_t &unixTime) {
  if (regs[0] & SECONDS_VL_BIT) {
    return false;
  }

  CivilTime time;
  time.second = bcdToDec(regs[0] & 0x7F);
  time.minute = bcdToDec(regs[1] & 0x7F);
  time.hour = bcdToDec(regs[2] & 0x3F);
  time.day = bcdToDec(regs[3] & 0x3F);
  time.weekday = bcdToDec(regs[4] & 0x07);
  time.month = bcdToDec(regs[5] & 0x1F);
  time.year = static_cast<uint16_t>(2000U + bcdToDec(regs[6]));
  return unixTimeFromCivil(time, unixTime);
}

bool readUnixTimeAtBase(uint8_t regBase, uint32_t &unixTime) {
  uint8_t regs[7] = {};
  if (!readRegisterBlock(regBase, regs, sizeof(regs))) {
    return false;
  }
  return decodeRtcRegisters(regs, unixTime);
}

bool chooseTimeRegisterBase() {
  uint32_t unixTime = 0;
  if (readUnixTimeAtBase(REG_SECONDS_PCF8563, unixTime)) {
    timeRegisterBase = REG_SECONDS_PCF8563;
    rtcStatus.timeValid = true;
    rtcStatus.source = TimeSource::RTC;
    rtcStatus.unixTime = unixTime;
    return true;
  }
  if (readUnixTimeAtBase(REG_SECONDS_PCF85063, unixTime)) {
    timeRegisterBase = REG_SECONDS_PCF85063;
    rtcStatus.timeValid = true;
    rtcStatus.source = TimeSource::RTC;
    rtcStatus.unixTime = unixTime;
    return true;
  }

  timeRegisterBase = REG_SECONDS_PCF8563;
  rtcStatus.timeValid = false;
  rtcStatus.source = TimeSource::Unknown;
  rtcStatus.unixTime = 0;
  return false;
}

bool writeTimeRegisters(const CivilTime &time) {
  const uint8_t regs[7] = {
      decToBcd(time.second),
      decToBcd(time.minute),
      decToBcd(time.hour),
      decToBcd(time.day),
      decToBcd(time.weekday),
      decToBcd(time.month),
      decToBcd(static_cast<uint8_t>(time.year - 2000U)),
  };

  const bool stopped = setStopBit(true);
  const bool wrote = stopped && writeRegisterBlock(timeRegisterBase, regs, 7);
  const bool restarted = setStopBit(false);
  return stopped && wrote && restarted;
}

void logUnixTime(const char *prefix, uint32_t unixTime) {
  CivilTime time;
  if (!civilFromUnixTime(unixTime, time)) {
    Serial.print("RTC: ");
    Serial.print(prefix == nullptr ? "time" : prefix);
    Serial.print(" unix=");
    Serial.println(unixTime);
    return;
  }

  char buffer[32];
  snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02uZ",
           time.year, time.month, time.day, time.hour, time.minute,
           time.second);
  Serial.print("RTC: ");
  Serial.print(prefix == nullptr ? "time" : prefix);
  Serial.print(" ");
  Serial.println(buffer);
}

} // namespace

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

const Status &status() { return rtcStatus; }

bool begin() {
  if (rtcStatus.initialized && rtcStatus.present) {
    return true;
  }

  if (!rtcStatus.initialized) {
    rtcStatus.initialized = true;
    Wire.setPins(pins::i2cSda, pins::i2cScl);
    Wire.begin();
    Wire.setClock(100000);
  }

  rtcStatus.present = probeRtc();
  if (!rtcStatus.present) {
    Serial.println("RTC: PCF8563/PCF85063 not found at 0x51");
    return false;
  }

  uint8_t control1 = 0;
  if (readRegister(REG_CONTROL_1, control1) &&
      (control1 & CONTROL_1_STOP_BIT)) {
    writeRegister(REG_CONTROL_1, control1 & ~CONTROL_1_STOP_BIT);
  }

  const bool timeValid = chooseTimeRegisterBase();
  Serial.print("RTC: found at 0x51 base=0x");
  Serial.print(timeRegisterBase, HEX);
  Serial.print(" time_valid=");
  Serial.println(timeValid);
  if (timeValid) {
    logUnixTime("restored", rtcStatus.unixTime);
  }
  return true;
}

bool readUnixTime(uint32_t &unixTime) {
  if (!rtcStatus.present && !begin()) {
    return false;
  }

  const bool ok = readUnixTimeAtBase(timeRegisterBase, unixTime);
  rtcStatus.timeValid = ok;
  if (ok) {
    rtcStatus.source = TimeSource::RTC;
    rtcStatus.unixTime = unixTime;
  } else {
    rtcStatus.source = TimeSource::Unknown;
    rtcStatus.unixTime = 0;
  }
  return ok;
}

bool syncFromUnixTime(uint32_t unixTime, const char *source) {
  if (unixTime < MIN_VALID_UNIX_TIME || unixTime >= MAX_VALID_UNIX_TIME) {
    Serial.print("RTC: rejected sync time from ");
    Serial.print(source == nullptr ? "unknown" : source);
    Serial.print(" unix=");
    Serial.println(unixTime);
    rtcStatus.lastSyncOk = false;
    return false;
  }

  if (!rtcStatus.present && !begin()) {
    rtcStatus.lastSyncOk = false;
    return false;
  }

  CivilTime civil;
  if (!civilFromUnixTime(unixTime, civil)) {
    rtcStatus.lastSyncOk = false;
    return false;
  }

  constexpr uint8_t SYNC_ATTEMPTS = 3;
  for (uint8_t attempt = 1; attempt <= SYNC_ATTEMPTS; attempt++) {
    if (!writeTimeRegisters(civil)) {
      Serial.print("RTC: sync write failed attempt=");
      Serial.print(attempt);
      Serial.print(" source=");
      Serial.println(source == nullptr ? "unknown" : source);
      delay(20);
      continue;
    }

    delay(20);
    uint32_t readBack = 0;
    if (readUnixTimeAtBase(timeRegisterBase, readBack) &&
        labs(static_cast<long>(readBack) - static_cast<long>(unixTime)) <= 2L) {
      rtcStatus.timeValid = true;
      rtcStatus.lastSyncOk = true;
      rtcStatus.source = TimeSource::BLE;
      rtcStatus.unixTime = unixTime;
      rtcStatus.lastSyncMs = millis();
      logUnixTime(source == nullptr ? "synced" : source, unixTime);
      return true;
    }

    Serial.print("RTC: sync readback failed attempt=");
    Serial.print(attempt);
    Serial.print(" source=");
    Serial.println(source == nullptr ? "unknown" : source);
    delay(20);
  }

  setStopBit(false);
  rtcStatus.lastSyncOk = false;
  return false;
}

} // namespace xiao_round::rtc
