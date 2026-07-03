#include "serial_simulator.hpp"

#include "serial_simulator_core.hpp"

#include <ctype.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>

namespace xiao_round {
namespace {

constexpr uint16_t MAX_ROUTE_PACKET_BYTES = 512;
constexpr uint16_t MAX_FALLBACK_FRAME_BYTES = MAX_ROUTE_PACKET_BYTES + 4;
constexpr uint8_t DEFAULT_SD_LIST_ENTRIES = 24;
constexpr uint8_t MAX_SD_LIST_ENTRIES = 64;
constexpr uint8_t MAX_SD_LIST_PATH_LEN = 63;

char *skipSpaces(char *text) {
  while (text != nullptr && *text != '\0' &&
         isspace(static_cast<unsigned char>(*text))) {
    text++;
  }
  return text;
}

int hexNibble(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

bool parseUnsignedLongToken(const char *token, unsigned long &out) {
  return serial_simulator_core::parseUnsignedDecimalToken(token, out);
}

bool parseI16Token(const char *token, long &out) {
  return serial_simulator_core::parseSignedDecimalTokenInRange(
      token, INT16_MIN, INT16_MAX, out);
}

bool parseI32Token(const char *token, long &out) {
  return serial_simulator_core::parseSignedDecimalTokenInRange(
      token, INT32_MIN, INT32_MAX, out);
}

bool parseU16Token(const char *token, unsigned long &out) {
  return serial_simulator_core::parseUnsignedDecimalTokenInRange(
      token, 0, UINT16_MAX, out);
}

bool parseU32Token(const char *token, unsigned long &out) {
  return serial_simulator_core::parseUnsignedDecimalTokenInRange(
      token, 0, UINT32_MAX, out);
}

} // namespace

void SerialSimulator::begin(BLENavigationServer &targetServer,
                            PowerManager &targetPower,
                            MapLite &targetMapLite, RoundUi &targetUi) {
  server = &targetServer;
  powerManager = &targetPower;
  mapLite = &targetMapLite;
  roundUi = &targetUi;
  lineLen = 0;
  line[0] = '\0';
  Serial.println("SerialSim: ready, type HELP for commands");
}

void SerialSimulator::update() {
  if (server == nullptr) {
    return;
  }

  while (Serial.available() > 0) {
    const char ch = static_cast<char>(Serial.read());
    if (ch == '\r') {
      continue;
    }
    if (ch == '\n') {
      line[lineLen] = '\0';
      processLine(line);
      lineLen = 0;
      line[0] = '\0';
      if (diagnosticRequestPending) {
        return;
      }
      continue;
    }
    if (static_cast<size_t>(lineLen) + 1 >= sizeof(line)) {
      lineLen = 0;
      line[0] = '\0';
      Serial.println("SerialSim: line too long, dropped");
      continue;
    }
    line[lineLen++] = ch;
  }
}

bool SerialSimulator::takeDiagnosticRequest() {
  if (!diagnosticRequestPending) {
    return false;
  }
  diagnosticRequestPending = false;
  return true;
}

void SerialSimulator::processLine(char *input) {
  char *lineStart = skipSpaces(input);
  if (lineStart == nullptr || *lineStart == '\0') {
    return;
  }

  char *command = lineStart;
  char *args = command;
  while (*args != '\0' && !isspace(static_cast<unsigned char>(*args))) {
    args++;
  }
  if (*args == '\0') {
    args = nullptr;
  } else {
    *args = '\0';
    args = skipSpaces(args + 1);
    if (args != nullptr && *args == '\0') {
      args = nullptr;
    }
  }

  if (strcasecmp(command, "HELP") == 0) {
    printHelp();
    return;
  }
  if (strcasecmp(command, "SIM") == 0) {
    if (args != nullptr && strcasecmp(args, "ON") == 0) {
      server->beginSimulationSession();
    } else if (args != nullptr && strcasecmp(args, "OFF") == 0) {
      server->endSimulationSession();
    } else {
      Serial.println("SerialSim: SIM expects ON|OFF");
    }
    return;
  }
  if (strcasecmp(command, "BLE") == 0) {
    if (args != nullptr && strcasecmp(args, "DISCONNECT") == 0) {
      server->requestBleReset("serial-sim", false);
      return;
    }
    if (args != nullptr && strcasecmp(args, "RESET") == 0) {
      server->requestBleReset("serial-sim", true);
      return;
    }
    Serial.println("SerialSim: BLE expects DISCONNECT|RESET");
    return;
  }
  if (strcasecmp(command, "DIAG") == 0 ||
      strcasecmp(command, "STATUS") == 0) {
    diagnosticRequestPending = true;
    Serial.println("SerialSim: diagnostic snapshot requested");
    return;
  }
  if (strcasecmp(command, "NAV") == 0) {
    if (args == nullptr || strlen(args) > 127) {
      Serial.println("SerialSim: NAV expects Icon|Meters|Instruction");
      return;
    }
    server->injectNavigationWrite(reinterpret_cast<const uint8_t *>(args),
                                  strlen(args));
    return;
  }
  if (strcasecmp(command, "BRIGHTNESS") == 0 ||
      strcasecmp(command, "BRI") == 0) {
    uint8_t brightness = 0;
    if (powerManager == nullptr ||
        !parseBrightnessPayload(args, brightness)) {
      Serial.println("SerialSim: BRIGHTNESS expects percent 5..100");
      return;
    }
    powerManager->setTargetBrightness(brightness);
    return;
  }
  if (strcasecmp(command, "BATCAL") == 0) {
    uint16_t measuredMillivolts = 0;
    if (powerManager == nullptr ||
        !parseBatteryCalibrationPayload(args, measuredMillivolts)) {
      Serial.println("SerialSim: BATCAL expects measured battery millivolts");
      return;
    }
    powerManager->calibrateBatteryMillivolts(measuredMillivolts);
    return;
  }
  if (strcasecmp(command, "TOUCH") == 0) {
    TouchGesture gesture = TouchGesture::TapCenter;
    if (powerManager == nullptr || roundUi == nullptr ||
        !parseTouchGesture(args, gesture)) {
      Serial.println("SerialSim: TOUCH expects tap|long|left|right|up|down");
      return;
    }
    roundUi->handleGesture(gesture, *server, *powerManager);
    return;
  }
  if (strcasecmp(command, "MAPPROBE") == 0) {
    int32_t mapMetersX = 0;
    int32_t mapMetersY = 0;
    if (mapLite == nullptr ||
        !parseMapProbePayload(args, mapMetersX, mapMetersY)) {
      Serial.println("SerialSim: MAPPROBE expects mapMetersX mapMetersY");
      return;
    }
    mapLite->probeBlock(mapMetersX, mapMetersY);
    return;
  }
  if (strcasecmp(command, "MAPLITE") == 0) {
    if (mapLite == nullptr || args == nullptr) {
      Serial.println("SerialSim: MAPLITE expects ON|OFF");
      return;
    }
    if (strcasecmp(args, "ON") == 0) {
      mapLite->setExperimentEnabled(true);
      return;
    }
    if (strcasecmp(args, "OFF") == 0) {
      mapLite->setExperimentEnabled(false);
      return;
    }
    Serial.println("SerialSim: MAPLITE expects ON|OFF");
    return;
  }
  if (strcasecmp(command, "SDLS") == 0) {
    const char *path = "/";
    uint8_t maxEntries = DEFAULT_SD_LIST_ENTRIES;
    if (mapLite == nullptr || !parseSdListPayload(args, path, maxEntries)) {
      Serial.println("SerialSim: SDLS expects [path] [maxEntries 1..64]");
      return;
    }
    mapLite->printDirectory(path, maxEntries);
    return;
  }

  uint8_t payload[MAX_FALLBACK_FRAME_BYTES];
  uint16_t len = 0;
  if (strcasecmp(command, "GPS") == 0) {
    if (!buildGpsPayload(args, payload, sizeof(payload), len)) {
      Serial.println("SerialSim: GPS expects lat lon [heading unix speed alt distance elapsed remaining]");
      return;
    }
    server->injectGpsWrite(payload, len, "serial-sim");
    return;
  }
  if (strcasecmp(command, "SET") == 0) {
    if (!buildSettingPayload(args, payload, sizeof(payload), len)) {
      Serial.println("SerialSim: SET expects id value");
      return;
    }
    server->injectSettingsWrite(payload, len, "serial-sim");
    return;
  }
  if (strcasecmp(command, "ROUTECLEAR") == 0) {
    server->injectRouteWrite(payload, 0, "serial-sim");
    return;
  }
  if (strcasecmp(command, "GPSHEX") == 0) {
    if (!parseHexPayload(args, payload, 30, len)) {
      Serial.println("SerialSim: invalid GPSHEX payload");
      return;
    }
    server->injectGpsWrite(payload, len, "serial-sim");
    return;
  }
  if (strcasecmp(command, "ROUTEHEX") == 0) {
    if (!parseHexPayload(args, payload, MAX_ROUTE_PACKET_BYTES, len)) {
      Serial.println("SerialSim: invalid ROUTEHEX payload");
      return;
    }
    server->injectRouteWrite(payload, len, "serial-sim");
    return;
  }
  if (strcasecmp(command, "SETHEX") == 0) {
    if (!parseHexPayload(args, payload, 5, len)) {
      Serial.println("SerialSim: invalid SETHEX payload");
      return;
    }
    server->injectSettingsWrite(payload, len, "serial-sim");
    return;
  }
  if (strcasecmp(command, "FRAMEHEX") == 0) {
    if (!parseHexPayload(args, payload, sizeof(payload), len)) {
      Serial.println("SerialSim: invalid FRAMEHEX payload");
      return;
    }
    server->injectNavigationWrite(payload, len);
    return;
  }

  Serial.println("SerialSim: unknown command");
}

bool SerialSimulator::parseHexPayload(const char *hex, uint8_t *out,
                                      uint16_t outCapacity,
                                      uint16_t &outLen) const {
  if (hex == nullptr || out == nullptr) {
    return false;
  }

  outLen = 0;
  int high = -1;
  for (const char *cursor = hex; *cursor != '\0'; cursor++) {
    if (isspace(static_cast<unsigned char>(*cursor))) {
      continue;
    }
    const int nibble = hexNibble(*cursor);
    if (nibble < 0) {
      return false;
    }
    if (high < 0) {
      high = nibble;
      continue;
    }
    if (outLen >= outCapacity) {
      return false;
    }
    out[outLen++] = static_cast<uint8_t>((high << 4) | nibble);
    high = -1;
  }
  return high < 0;
}

bool SerialSimulator::appendI16(uint8_t *out, uint16_t outCapacity,
                                uint16_t &outLen, int16_t value) const {
  return appendU16(out, outCapacity, outLen, static_cast<uint16_t>(value));
}

bool SerialSimulator::appendU16(uint8_t *out, uint16_t outCapacity,
                                uint16_t &outLen, uint16_t value) const {
  if (outLen + 2 > outCapacity) {
    return false;
  }
  out[outLen++] = static_cast<uint8_t>(value & 0xFF);
  out[outLen++] = static_cast<uint8_t>((value >> 8) & 0xFF);
  return true;
}

bool SerialSimulator::appendI32(uint8_t *out, uint16_t outCapacity,
                                uint16_t &outLen, int32_t value) const {
  return appendU32(out, outCapacity, outLen, static_cast<uint32_t>(value));
}

bool SerialSimulator::appendU32(uint8_t *out, uint16_t outCapacity,
                                uint16_t &outLen, uint32_t value) const {
  if (outLen + 4 > outCapacity) {
    return false;
  }
  out[outLen++] = static_cast<uint8_t>(value & 0xFF);
  out[outLen++] = static_cast<uint8_t>((value >> 8) & 0xFF);
  out[outLen++] = static_cast<uint8_t>((value >> 16) & 0xFF);
  out[outLen++] = static_cast<uint8_t>((value >> 24) & 0xFF);
  return true;
}

bool SerialSimulator::buildGpsPayload(char *args, uint8_t *out,
                                      uint16_t outCapacity,
                                      uint16_t &outLen) const {
  if (args == nullptr || out == nullptr ||
      !serial_simulator_core::hasSpaceSeparatedTokenCountInRange(args, 2, 9)) {
    return false;
  }

  char *tokens[9] = {};
  uint8_t count = 0;
  for (char *token = strtok(args, " "); token != nullptr && count < 9;
       token = strtok(nullptr, " ")) {
    tokens[count++] = token;
  }
  if (count < 2) {
    return false;
  }

  long signedValue = 0;
  unsigned long unsignedValue = 0;
  outLen = 0;
  if (!parseI32Token(tokens[0], signedValue) ||
      !appendI32(out, outCapacity, outLen, signedValue) ||
      !parseI32Token(tokens[1], signedValue) ||
      !appendI32(out, outCapacity, outLen, signedValue)) {
    return false;
  }
  if (count >= 3 && (!parseU16Token(tokens[2], unsignedValue) ||
                     !appendU16(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  if (count >= 4 && (!parseU32Token(tokens[3], unsignedValue) ||
                     !appendU32(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  if (count >= 5 && (!parseU16Token(tokens[4], unsignedValue) ||
                     !appendU16(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  if (count >= 6 && (!parseI16Token(tokens[5], signedValue) ||
                     !appendI16(out, outCapacity, outLen, signedValue))) {
    return false;
  }
  if (count >= 7 && (!parseU32Token(tokens[6], unsignedValue) ||
                     !appendU32(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  if (count >= 8 && (!parseU32Token(tokens[7], unsignedValue) ||
                     !appendU32(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  if (count >= 9 && (!parseU32Token(tokens[8], unsignedValue) ||
                     !appendU32(out, outCapacity, outLen, unsignedValue))) {
    return false;
  }
  return true;
}

bool SerialSimulator::buildSettingPayload(char *args, uint8_t *out,
                                          uint16_t outCapacity,
                                          uint16_t &outLen) const {
  if (args == nullptr || out == nullptr || outCapacity < 5 ||
      !serial_simulator_core::hasSpaceSeparatedTokenCountInRange(args, 2, 2)) {
    return false;
  }

  char *id = strtok(args, " ");
  char *value = strtok(nullptr, " ");
  if (id == nullptr || value == nullptr) {
    return false;
  }
  unsigned long settingId = 0;
  long settingValue = 0;
  if (!serial_simulator_core::parseUnsignedDecimalTokenInRange(
          id, 0, 255, settingId) ||
      !parseI32Token(value, settingValue)) {
    return false;
  }
  outLen = 0;
  out[outLen++] = static_cast<uint8_t>(settingId);
  return appendI32(out, outCapacity, outLen, settingValue);
}

bool SerialSimulator::parseBrightnessPayload(const char *args,
                                             uint8_t &out) const {
  unsigned long value = 0;
  if (!serial_simulator_core::hasSpaceSeparatedTokenCountInRange(args, 1, 1)) {
    return false;
  }
  if (!serial_simulator_core::parseUnsignedDecimalTokenInRange(
          args, 5, 100, value)) {
    return false;
  }
  out = static_cast<uint8_t>(value);
  return true;
}

bool SerialSimulator::parseBatteryCalibrationPayload(const char *args,
                                                     uint16_t &out) const {
  unsigned long value = 0;
  if (!serial_simulator_core::hasSpaceSeparatedTokenCountInRange(args, 1, 1)) {
    return false;
  }
  if (!serial_simulator_core::parseUnsignedDecimalTokenInRange(
          args, 2500, 4500, value)) {
    return false;
  }
  out = static_cast<uint16_t>(value);
  return true;
}

bool SerialSimulator::parseMapProbePayload(char *args, int32_t &mapMetersX,
                                           int32_t &mapMetersY) const {
  if (args == nullptr) {
    return false;
  }
  char *x = strtok(args, " ");
  char *y = strtok(nullptr, " ");
  char *extra = strtok(nullptr, " ");
  if (x == nullptr || y == nullptr || extra != nullptr) {
    return false;
  }
  long parsedX = 0;
  long parsedY = 0;
  if (!parseI32Token(x, parsedX) || !parseI32Token(y, parsedY)) {
    return false;
  }
  mapMetersX = static_cast<int32_t>(parsedX);
  mapMetersY = static_cast<int32_t>(parsedY);
  return true;
}

bool SerialSimulator::parseSdListPayload(char *args, const char *&path,
                                         uint8_t &maxEntries) const {
  path = "/";
  maxEntries = DEFAULT_SD_LIST_ENTRIES;
  if (args == nullptr) {
    return true;
  }

  char *first = strtok(args, " ");
  char *second = strtok(nullptr, " ");
  char *extra = strtok(nullptr, " ");
  if (extra != nullptr) {
    return false;
  }

  unsigned long parsedEntries = 0;
  if (first == nullptr) {
    return true;
  }
  if (second == nullptr && parseUnsignedLongToken(first, parsedEntries)) {
    if (parsedEntries == 0 || parsedEntries > MAX_SD_LIST_ENTRIES) {
      return false;
    }
    maxEntries = static_cast<uint8_t>(parsedEntries);
    return true;
  }

  if (strlen(first) > MAX_SD_LIST_PATH_LEN) {
    return false;
  }
  path = first;
  if (second == nullptr) {
    return true;
  }
  if (!parseUnsignedLongToken(second, parsedEntries) || parsedEntries == 0 ||
      parsedEntries > MAX_SD_LIST_ENTRIES) {
    return false;
  }
  maxEntries = static_cast<uint8_t>(parsedEntries);
  return true;
}

bool SerialSimulator::parseTouchGesture(const char *args,
                                        TouchGesture &gesture) const {
  if (args == nullptr) {
    return false;
  }
  if (strcasecmp(args, "TAP") == 0 || strcasecmp(args, "CENTER") == 0) {
    gesture = TouchGesture::TapCenter;
    return true;
  }
  if (strcasecmp(args, "LONG") == 0 || strcasecmp(args, "LONGPRESS") == 0) {
    gesture = TouchGesture::LongPress;
    return true;
  }
  if (strcasecmp(args, "LEFT") == 0 || strcasecmp(args, "SWIPELEFT") == 0) {
    gesture = TouchGesture::SwipeLeft;
    return true;
  }
  if (strcasecmp(args, "RIGHT") == 0 || strcasecmp(args, "SWIPERIGHT") == 0) {
    gesture = TouchGesture::SwipeRight;
    return true;
  }
  if (strcasecmp(args, "UP") == 0 || strcasecmp(args, "SWIPEUP") == 0) {
    gesture = TouchGesture::SwipeUp;
    return true;
  }
  if (strcasecmp(args, "DOWN") == 0 || strcasecmp(args, "SWIPEDOWN") == 0) {
    gesture = TouchGesture::SwipeDown;
    return true;
  }
  return false;
}

void SerialSimulator::printHelp() const {
  Serial.println("SerialSim commands:");
  Serial.println("  SIM ON|OFF");
  Serial.println("  BLE DISCONNECT|RESET");
  Serial.println("  DIAG");
  Serial.println("  NAV icon|meters|instruction");
  Serial.println("  GPS lat lon [heading unix speedCmps alt distance elapsed remaining]");
  Serial.println("  SET id value");
  Serial.println("  SET 5 1");
  Serial.println("  BRIGHTNESS percent");
  Serial.println("  BATCAL measured_mV");
  Serial.println("  TOUCH tap|long|left|right|up|down");
  Serial.println("    settings: tap toggles orientation, long resets BLE");
  Serial.println("  MAPLITE ON|OFF");
  Serial.println("  MAPPROBE mapMetersX mapMetersY");
  Serial.println("  SDLS [path] [maxEntries]");
  Serial.println("  ROUTECLEAR");
  Serial.println("  GPSHEX <hex>, ROUTEHEX <hex>, SETHEX <hex>, FRAMEHEX <hex>");
}

} // namespace xiao_round
