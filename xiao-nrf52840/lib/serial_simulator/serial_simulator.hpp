#pragma once

#include <Arduino.h>

#include "ble_navigation.hpp"
#include "power_manager.hpp"
#include "map_lite.hpp"
#include "ui_round.hpp"

namespace xiao_round {

class SerialSimulator {
public:
  void begin(BLENavigationServer &targetServer, PowerManager &targetPower,
             MapLite &targetMapLite, RoundUi &targetUi);
  void update();

private:
  void processLine(char *line);
  bool parseHexPayload(const char *hex, uint8_t *out, uint16_t outCapacity,
                       uint16_t &outLen) const;
  bool appendI16(uint8_t *out, uint16_t outCapacity, uint16_t &outLen,
                 int16_t value) const;
  bool appendU16(uint8_t *out, uint16_t outCapacity, uint16_t &outLen,
                 uint16_t value) const;
  bool appendI32(uint8_t *out, uint16_t outCapacity, uint16_t &outLen,
                 int32_t value) const;
  bool appendU32(uint8_t *out, uint16_t outCapacity, uint16_t &outLen,
                 uint32_t value) const;
  bool buildGpsPayload(char *args, uint8_t *out, uint16_t outCapacity,
                       uint16_t &outLen) const;
  bool buildSettingPayload(char *args, uint8_t *out, uint16_t outCapacity,
                           uint16_t &outLen) const;
  bool parseBrightnessPayload(const char *args, uint8_t &out) const;
  bool parseMapProbePayload(char *args, int32_t &mapMetersX,
                            int32_t &mapMetersY) const;
  bool parseTouchGesture(const char *args, TouchGesture &gesture) const;
  void printHelp() const;

  BLENavigationServer *server = nullptr;
  PowerManager *powerManager = nullptr;
  MapLite *mapLite = nullptr;
  RoundUi *roundUi = nullptr;
  char line[1152] = "";
  uint16_t lineLen = 0;
};

} // namespace xiao_round
