#include <unity.h>

#include "serial_simulator_core.hpp"

namespace {

void testUnsignedDecimalParserAcceptsTrimmedPositiveNumbers() {
  unsigned long value = 0;
  TEST_ASSERT_TRUE(
      xiao_round::serial_simulator_core::parseUnsignedDecimalToken("42", value));
  TEST_ASSERT_EQUAL_UINT32(42, value);

  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::parseUnsignedDecimalToken(
      "  123  ", value));
  TEST_ASSERT_EQUAL_UINT32(123, value);
}

void testUnsignedDecimalParserRejectsNegativeAndMalformedTokens() {
  unsigned long value = 7;
  TEST_ASSERT_FALSE(
      xiao_round::serial_simulator_core::parseUnsignedDecimalToken("-1", value));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::parseUnsignedDecimalToken(
      " -1 ", value));
  TEST_ASSERT_FALSE(
      xiao_round::serial_simulator_core::parseUnsignedDecimalToken("1 2", value));
  TEST_ASSERT_FALSE(
      xiao_round::serial_simulator_core::parseUnsignedDecimalToken("", value));
}

void testUnsignedDecimalParserRejectsOutOfRangeTokens() {
  unsigned long value = 0;
  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::
                       parseUnsignedDecimalTokenInRange("65535", 0, 65535,
                                                        value));
  TEST_ASSERT_EQUAL_UINT32(65535, value);
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        parseUnsignedDecimalTokenInRange("65536", 0, 65535,
                                                         value));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::parseUnsignedDecimalToken(
      "999999999999999999999999999999999999999999", value));
}

void testSignedDecimalParserAcceptsRangeAndRejectsOverflow() {
  long value = 0;
  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::
                       parseSignedDecimalTokenInRange("-32768", -32768, 32767,
                                                      value));
  TEST_ASSERT_EQUAL_INT32(-32768, value);
  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::
                       parseSignedDecimalTokenInRange("32767", -32768, 32767,
                                                      value));
  TEST_ASSERT_EQUAL_INT32(32767, value);
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        parseSignedDecimalTokenInRange("-32769", -32768, 32767,
                                                       value));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        parseSignedDecimalTokenInRange("32768", -32768, 32767,
                                                       value));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::parseSignedDecimalToken(
      "999999999999999999999999999999999999999999", value));
}

void testTokenCountRangeRejectsTooFewAndTooManyTokens() {
  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::
                       hasSpaceSeparatedTokenCountInRange("1 2 3", 2, 3));
  TEST_ASSERT_TRUE(xiao_round::serial_simulator_core::
                       hasSpaceSeparatedTokenCountInRange("  1\t2\n", 2, 2));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        hasSpaceSeparatedTokenCountInRange("1", 2, 3));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        hasSpaceSeparatedTokenCountInRange("1 2 3 4", 2, 3));
  TEST_ASSERT_FALSE(xiao_round::serial_simulator_core::
                        hasSpaceSeparatedTokenCountInRange(nullptr, 1, 1));
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testUnsignedDecimalParserAcceptsTrimmedPositiveNumbers);
  RUN_TEST(testUnsignedDecimalParserRejectsNegativeAndMalformedTokens);
  RUN_TEST(testUnsignedDecimalParserRejectsOutOfRangeTokens);
  RUN_TEST(testSignedDecimalParserAcceptsRangeAndRejectsOverflow);
  RUN_TEST(testTokenCountRangeRejectsTooFewAndTooManyTokens);
  return UNITY_END();
}
