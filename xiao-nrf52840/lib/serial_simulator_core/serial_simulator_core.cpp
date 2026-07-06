#include "serial_simulator_core.hpp"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>

namespace xiao_round {
namespace serial_simulator_core {
namespace {

const char *skipSpaces(const char *text) {
  while (text != nullptr && *text != '\0' &&
         isspace(static_cast<unsigned char>(*text))) {
    text++;
  }
  return text;
}

} // namespace

bool parseSignedDecimalToken(const char *token, long &out) {
  const char *start = skipSpaces(token);
  if (start == nullptr || *start == '\0') {
    return false;
  }

  char *end = nullptr;
  errno = 0;
  out = strtol(start, &end, 10);
  if (errno == ERANGE) {
    return false;
  }
  const char *trimmedEnd = skipSpaces(end);
  return trimmedEnd != start && trimmedEnd != nullptr && *trimmedEnd == '\0';
}

bool parseSignedDecimalTokenInRange(const char *token, long minValue,
                                    long maxValue, long &out) {
  long value = 0;
  if (!parseSignedDecimalToken(token, value) || value < minValue ||
      value > maxValue) {
    return false;
  }
  out = value;
  return true;
}

bool parseUnsignedDecimalToken(const char *token, unsigned long &out) {
  const char *start = skipSpaces(token);
  if (start == nullptr || *start == '\0' || *start == '-') {
    return false;
  }

  char *end = nullptr;
  errno = 0;
  out = strtoul(start, &end, 10);
  if (errno == ERANGE) {
    return false;
  }
  const char *trimmedEnd = skipSpaces(end);
  return trimmedEnd != start && trimmedEnd != nullptr && *trimmedEnd == '\0';
}

bool parseUnsignedDecimalTokenInRange(const char *token,
                                      unsigned long minValue,
                                      unsigned long maxValue,
                                      unsigned long &out) {
  unsigned long value = 0;
  if (!parseUnsignedDecimalToken(token, value) || value < minValue ||
      value > maxValue) {
    return false;
  }
  out = value;
  return true;
}

bool hasSpaceSeparatedTokenCountInRange(const char *text, unsigned int minCount,
                                        unsigned int maxCount) {
  unsigned int count = 0;
  bool inToken = false;
  for (const char *cursor = text; cursor != nullptr && *cursor != '\0';
       cursor++) {
    const bool isSpace = isspace(static_cast<unsigned char>(*cursor));
    if (isSpace) {
      inToken = false;
      continue;
    }
    if (!inToken) {
      count++;
      if (count > maxCount) {
        return false;
      }
      inToken = true;
    }
  }
  return count >= minCount;
}

} // namespace serial_simulator_core
} // namespace xiao_round
