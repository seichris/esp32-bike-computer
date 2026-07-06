#include <unity.h>

#include "rtc_core.hpp"

namespace {

void testCivilUnixConversionHandlesLeapDayAndWeekday() {
  xiao_round::rtc_core::CivilTime time;
  TEST_ASSERT_TRUE(
      xiao_round::rtc_core::civilFromUnixTime(1709164800UL, time));
  TEST_ASSERT_EQUAL_UINT16(2024, time.year);
  TEST_ASSERT_EQUAL_UINT8(2, time.month);
  TEST_ASSERT_EQUAL_UINT8(29, time.day);
  TEST_ASSERT_EQUAL_UINT8(0, time.hour);
  TEST_ASSERT_EQUAL_UINT8(0, time.minute);
  TEST_ASSERT_EQUAL_UINT8(0, time.second);
  TEST_ASSERT_EQUAL_UINT8(4, time.weekday);

  uint32_t unixTime = 0;
  TEST_ASSERT_TRUE(xiao_round::rtc_core::unixTimeFromCivil(time, unixTime));
  TEST_ASSERT_EQUAL_UINT32(1709164800UL, unixTime);
}

void testCivilUnixConversionRejectsOutOfRangeAndInvalidDates() {
  xiao_round::rtc_core::CivilTime time;
  TEST_ASSERT_FALSE(
      xiao_round::rtc_core::civilFromUnixTime(1704067199UL, time));
  TEST_ASSERT_FALSE(
      xiao_round::rtc_core::civilFromUnixTime(4102444800UL, time));

  uint32_t unixTime = 0;
  time.year = 2025;
  time.month = 2;
  time.day = 29;
  TEST_ASSERT_FALSE(xiao_round::rtc_core::unixTimeFromCivil(time, unixTime));

  time.year = 2024;
  time.month = 13;
  time.day = 1;
  TEST_ASSERT_FALSE(xiao_round::rtc_core::unixTimeFromCivil(time, unixTime));
}

void testRegisterDecodeRejectsVoltageLowAndInvalidBcd() {
  uint32_t unixTime = 0;
  const uint8_t voltageLow[7] = {0x80, 0x00, 0x00, 0x01,
                                 0x01, 0x01, 0x24};
  TEST_ASSERT_FALSE(
      xiao_round::rtc_core::decodeRtcRegisters(voltageLow, unixTime));

  const uint8_t invalidDayBcd[7] = {0x00, 0x00, 0x00, 0x1A,
                                    0x01, 0x01, 0x24};
  TEST_ASSERT_FALSE(
      xiao_round::rtc_core::decodeRtcRegisters(invalidDayBcd, unixTime));
}

void testRegisterEncodeDecodeRoundTripsValidTime() {
  xiao_round::rtc_core::CivilTime time;
  TEST_ASSERT_TRUE(
      xiao_round::rtc_core::civilFromUnixTime(1783080000UL, time));

  uint8_t regs[7] = {};
  TEST_ASSERT_TRUE(xiao_round::rtc_core::encodeRtcRegisters(time, regs));
  TEST_ASSERT_EQUAL_UINT8(0x00, regs[0]);
  TEST_ASSERT_EQUAL_UINT8(0x00, regs[1]);
  TEST_ASSERT_EQUAL_UINT8(0x12, regs[2]);
  TEST_ASSERT_EQUAL_UINT8(0x03, regs[3]);
  TEST_ASSERT_EQUAL_UINT8(0x26, regs[6]);

  uint32_t unixTime = 0;
  TEST_ASSERT_TRUE(xiao_round::rtc_core::decodeRtcRegisters(regs, unixTime));
  TEST_ASSERT_EQUAL_UINT32(1783080000UL, unixTime);
}

void testRegisterEncodeRejectsInvalidCivilTime() {
  uint8_t regs[7] = {};
  xiao_round::rtc_core::CivilTime time;
  time.year = 2026;
  time.month = 7;
  time.day = 3;
  time.hour = 12;
  time.minute = 0;
  time.second = 0;
  time.weekday = 7;
  TEST_ASSERT_FALSE(xiao_round::rtc_core::encodeRtcRegisters(time, regs));
}

void testSourceNamesAreStableForDiagnostics() {
  TEST_ASSERT_EQUAL_STRING(
      "unknown",
      xiao_round::rtc_core::sourceName(
          xiao_round::rtc_core::TimeSource::Unknown));
  TEST_ASSERT_EQUAL_STRING(
      "rtc",
      xiao_round::rtc_core::sourceName(xiao_round::rtc_core::TimeSource::RTC));
  TEST_ASSERT_EQUAL_STRING(
      "ble",
      xiao_round::rtc_core::sourceName(xiao_round::rtc_core::TimeSource::BLE));
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testCivilUnixConversionHandlesLeapDayAndWeekday);
  RUN_TEST(testCivilUnixConversionRejectsOutOfRangeAndInvalidDates);
  RUN_TEST(testRegisterDecodeRejectsVoltageLowAndInvalidBcd);
  RUN_TEST(testRegisterEncodeDecodeRoundTripsValidTime);
  RUN_TEST(testRegisterEncodeRejectsInvalidCivilTime);
  RUN_TEST(testSourceNamesAreStableForDiagnostics);
  return UNITY_END();
}
