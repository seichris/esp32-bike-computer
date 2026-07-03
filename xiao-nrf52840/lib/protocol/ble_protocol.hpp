#pragma once

#ifdef ARDUINO
#include <Arduino.h>
#else
#include <cstddef>
#include <cstdint>
#endif

namespace bike_ble {

constexpr const char *SERVICE_UUID = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800";
constexpr uint16_t NAV_CHAR_UUID = 0x2A6E;
constexpr uint16_t ROUTE_CHAR_UUID = 0x2A6F;
constexpr uint16_t GPS_CHAR_UUID = 0x2A72;
constexpr uint16_t SETTINGS_CHAR_UUID = 0x2A73;
constexpr const char *AUTH_CHAR_UUID = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002";

constexpr const char *FALLBACK_ROUTE_PREFIX = "MAPR";
constexpr const char *FALLBACK_GPS_PREFIX = "GPSP";
constexpr const char *FALLBACK_SETTINGS_PREFIX = "MSET";
constexpr uint16_t MAX_ROUTE_POINTS = 128;

struct NavigationData {
  uint8_t iconId = 0;
  uint16_t distanceMeters = 0;
  char instruction[64] = "";
};

struct RoutePoint {
  int32_t latMicrodegrees = 0;
  int32_t lonMicrodegrees = 0;
};

struct RouteSummary {
  bool loaded = false;
  uint32_t hash = 0;
  uint16_t lengthBytes = 0;
  uint16_t pointCount = 0;
  uint16_t storedPointCount = 0;
  bool truncated = false;
  int32_t startLatMicrodegrees = 0;
  int32_t startLonMicrodegrees = 0;
  int32_t endLatMicrodegrees = 0;
  int32_t endLonMicrodegrees = 0;
  RoutePoint points[MAX_ROUTE_POINTS];
};

struct GpsPosition {
  int32_t latMicrodegrees = 0;
  int32_t lonMicrodegrees = 0;
  uint16_t headingDegrees = 0;
  bool hasUnixTime = false;
  uint32_t unixTime = 0;
  bool hasSpeed = false;
  uint16_t speedCmps = 0;
  bool hasAltitude = false;
  int16_t altitudeMeters = 0;
  bool hasDistanceTraveled = false;
  uint32_t distanceTraveledMeters = 0;
  bool hasElapsedTime = false;
  uint32_t elapsedSeconds = 0;
  bool hasRouteRemaining = false;
  uint32_t routeRemainingMeters = 0;
};

struct MapRenderSettings {
  uint8_t minPolygonSize = 0;
  uint8_t detailLevel = 2;
  uint8_t routeLineWidth = 4;
  uint8_t streetLineWidthBoost = 0;
  uint8_t positionMarkerScale = 2;
  uint8_t displayRotation = 0;
  uint8_t mapRotationMode = 0;
  uint8_t zoomLevel = 2;
  uint8_t tapToSwitchScreens = 0;
  uint32_t visibilityMask = 0xFFFFFFFF;
};

struct MapSettingPacket {
  uint8_t id = 0;
  int32_t value = 0;
};

bool hasFramePrefix(const uint8_t *data, size_t len, const char *prefix);
bool parseNavigationData(const uint8_t *data, size_t len, NavigationData &out);
bool parseGpsPosition(const uint8_t *data, size_t len, GpsPosition &out);
bool parseMapSetting(const uint8_t *data, size_t len, MapSettingPacket &out);
bool applyMapSetting(const MapSettingPacket &packet, MapRenderSettings &settings);
RouteSummary summarizeRoute(const uint8_t *data, size_t len);
bool parseRouteGeometry(const uint8_t *data, size_t len, RouteSummary &out);

} // namespace bike_ble
