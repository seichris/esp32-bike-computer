#pragma once

namespace xiao_round {
namespace serial_simulator_core {

bool parseSignedDecimalToken(const char *token, long &out);
bool parseSignedDecimalTokenInRange(const char *token, long minValue,
                                    long maxValue, long &out);
bool parseUnsignedDecimalToken(const char *token, unsigned long &out);
bool parseUnsignedDecimalTokenInRange(const char *token,
                                      unsigned long minValue,
                                      unsigned long maxValue,
                                      unsigned long &out);
bool hasSpaceSeparatedTokenCountInRange(const char *text, unsigned int minCount,
                                        unsigned int maxCount);

} // namespace serial_simulator_core
} // namespace xiao_round
