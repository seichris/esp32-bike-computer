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

Status rtcStatus;
uint8_t timeRegisterBase = REG_SECONDS_PCF8563;

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

bool readUnixTimeAtBase(uint8_t regBase, uint32_t &unixTime) {
  uint8_t regs[7] = {};
  if (!readRegisterBlock(regBase, regs, sizeof(regs))) {
    return false;
  }
  return rtc_core::decodeRtcRegisters(regs, unixTime);
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

bool writeTimeRegisters(const rtc_core::CivilTime &time) {
  uint8_t regs[7] = {};
  if (!rtc_core::encodeRtcRegisters(time, regs)) {
    return false;
  }

  const bool stopped = setStopBit(true);
  const bool wrote = stopped && writeRegisterBlock(timeRegisterBase, regs, 7);
  const bool restarted = setStopBit(false);
  return stopped && wrote && restarted;
}

void logUnixTime(const char *prefix, uint32_t unixTime) {
  rtc_core::CivilTime time;
  if (!rtc_core::civilFromUnixTime(unixTime, time)) {
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
  return rtc_core::sourceName(source);
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
  if (unixTime < rtc_core::MIN_VALID_UNIX_TIME ||
      unixTime >= rtc_core::MAX_VALID_UNIX_TIME) {
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

  rtc_core::CivilTime civil;
  if (!rtc_core::civilFromUnixTime(unixTime, civil)) {
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
