#include "ble_protocol.hpp"

#include <cmath>
#include <cstring>
#include <stdlib.h>

namespace bike_ble {
namespace {

template <typename T> T readLittleEndian(const uint8_t *data) {
  T value;
  memcpy(&value, data, sizeof(value));
  return value;
}

template <typename T> T clampValue(T value, T minValue, T maxValue) {
  if (value < minValue) {
    return minValue;
  }
  if (value > maxValue) {
    return maxValue;
  }
  return value;
}

double degreesToRadians(double degrees) {
  return degrees * 0.017453292519943295;
}

double approximateMetersBetween(int32_t latA, int32_t lonA, int32_t latB,
                                int32_t lonB) {
  const double midLatDegrees =
      (static_cast<double>(latA) + static_cast<double>(latB)) / 2000000.0;
  const double metersPerMicrodegreeLat = 0.11132;
  const double latMeters =
      static_cast<double>(latB - latA) * metersPerMicrodegreeLat;
  const double lonMeters = static_cast<double>(lonB - lonA) *
                           metersPerMicrodegreeLat *
                           std::cos(degreesToRadians(midLatDegrees));
  return std::sqrt((latMeters * latMeters) + (lonMeters * lonMeters));
}

bool isSupportedGpsPayloadLength(size_t len) {
  switch (len) {
  case 8:
  case 10:
  case 14:
  case 16:
  case 18:
  case 22:
  case 26:
  case 30:
    return true;
  default:
    return false;
  }
}

} // namespace

bool hasFramePrefix(const uint8_t *data, size_t len, const char *prefix) {
  return data != nullptr && prefix != nullptr && len >= 4 &&
         memcmp(data, prefix, 4) == 0;
}

bool parseNavigationData(const uint8_t *data, size_t len, NavigationData &out) {
  if (data == nullptr || len == 0 || len >= 128) {
    return false;
  }

  char payload[128];
  memcpy(payload, data, len);
  payload[len] = '\0';

  char *firstPipe = strchr(payload, '|');
  if (firstPipe == nullptr) {
    return false;
  }
  char *secondPipe = strchr(firstPipe + 1, '|');
  if (secondPipe == nullptr) {
    return false;
  }

  *firstPipe = '\0';
  *secondPipe = '\0';

  char *end = nullptr;
  long icon = strtol(payload, &end, 10);
  if (end == payload || *end != '\0') {
    return false;
  }

  end = nullptr;
  long distance = strtol(firstPipe + 1, &end, 10);
  if (end == firstPipe + 1 || *end != '\0') {
    return false;
  }

  out.iconId = static_cast<uint8_t>(clampValue<long>(icon, 0, 255));
  out.distanceMeters =
      static_cast<uint16_t>(clampValue<long>(distance, 0, 65535));
  strncpy(out.instruction, secondPipe + 1, sizeof(out.instruction) - 1);
  out.instruction[sizeof(out.instruction) - 1] = '\0';
  return true;
}

RouteSummary summarizeRoute(const uint8_t *data, size_t len) {
  RouteSummary summary;
  parseRouteGeometry(data, len, summary);
  return summary;
}

bool parseRouteGeometry(const uint8_t *data, size_t len, RouteSummary &out) {
  out = RouteSummary{};
  if (data == nullptr || len < 8) {
    return false;
  }

  const size_t deltaBytes = len - 8;
  if ((deltaBytes % 4) != 0) {
    return false;
  }

  uint32_t hash = 0;
  for (size_t i = 0; i < len; i++) {
    hash = hash * 31U + data[i];
  }

  out.loaded = true;
  out.hash = hash;
  out.lengthBytes = static_cast<uint16_t>(len > 65535 ? 65535 : len);
  out.pointCount = 1U + static_cast<uint16_t>(deltaBytes / 4);
  out.truncated = out.pointCount > MAX_ROUTE_POINTS;

  int32_t lat = readLittleEndian<int32_t>(data);
  int32_t lon = readLittleEndian<int32_t>(data + 4);
  out.startLatMicrodegrees = lat;
  out.startLonMicrodegrees = lon;
  double totalDistanceMeters = 0.0;

  auto storePoint = [&out](uint16_t index, int32_t pointLat, int32_t pointLon) {
    if (index >= MAX_ROUTE_POINTS) {
      return;
    }
    out.points[index].latMicrodegrees = pointLat;
    out.points[index].lonMicrodegrees = pointLon;
    out.storedPointCount = index + 1;
  };

  storePoint(0, lat, lon);

  uint16_t pointIndex = 1;
  for (size_t offset = 8; offset + 4 <= len; offset += 4) {
    const int32_t previousLat = lat;
    const int32_t previousLon = lon;
    lat += readLittleEndian<int16_t>(data + offset);
    lon += readLittleEndian<int16_t>(data + offset + 2);
    totalDistanceMeters +=
        approximateMetersBetween(previousLat, previousLon, lat, lon);
    storePoint(pointIndex, lat, lon);
    pointIndex++;
  }

  out.endLatMicrodegrees = lat;
  out.endLonMicrodegrees = lon;
  out.totalDistanceMeters = static_cast<uint32_t>(totalDistanceMeters + 0.5);
  return true;
}

bool isDuplicateRouteSummary(const RouteSummary &summary, uint32_t lastHash,
                             uint16_t lastLengthBytes) {
  return summary.loaded && summary.hash == lastHash &&
         summary.lengthBytes == lastLengthBytes;
}

bool parseGpsPosition(const uint8_t *data, size_t len, GpsPosition &out) {
  if (data == nullptr || !isSupportedGpsPayloadLength(len)) {
    return false;
  }

  out = GpsPosition{};
  out.latMicrodegrees = readLittleEndian<int32_t>(data);
  out.lonMicrodegrees = readLittleEndian<int32_t>(data + 4);

  if (len >= 10) {
    out.headingDegrees = readLittleEndian<uint16_t>(data + 8);
  }
  if (len >= 14) {
    out.hasUnixTime = true;
    out.unixTime = readLittleEndian<uint32_t>(data + 10);
  }
  if (len >= 16) {
    const uint16_t speed = readLittleEndian<uint16_t>(data + 14);
    out.hasSpeed = speed != 0xFFFF;
    out.speedCmps = out.hasSpeed ? speed : 0;
  }
  if (len >= 18) {
    out.hasAltitude = true;
    out.altitudeMeters = readLittleEndian<int16_t>(data + 16);
  }
  if (len >= 22) {
    out.hasDistanceTraveled = true;
    out.distanceTraveledMeters = readLittleEndian<uint32_t>(data + 18);
  }
  if (len >= 26) {
    out.hasElapsedTime = true;
    out.elapsedSeconds = readLittleEndian<uint32_t>(data + 22);
  }
  if (len >= 30) {
    const uint32_t remaining = readLittleEndian<uint32_t>(data + 26);
    out.hasRouteRemaining = remaining != 0xFFFFFFFF;
    out.routeRemainingMeters = out.hasRouteRemaining ? remaining : 0;
  }

  return true;
}

bool parseMapSetting(const uint8_t *data, size_t len, MapSettingPacket &out) {
  if (data == nullptr || len != 5) {
    return false;
  }

  out.id = data[0];
  out.value = readLittleEndian<int32_t>(data + 1);
  return true;
}

bool applyMapSetting(const MapSettingPacket &packet,
                     MapRenderSettings &settings) {
  switch (packet.id) {
  case 1:
    settings.minPolygonSize =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 50));
    return true;
  case 2:
    settings.detailLevel =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 2));
    return true;
  case 3:
    settings.routeLineWidth =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 2, 48));
    return true;
  case 4:
    settings.displayRotation =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 3));
    return true;
  case 6:
    settings.mapRotationMode =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 1));
    return true;
  case 7:
    settings.zoomLevel =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 5));
    return true;
  case 8:
    settings.visibilityMask = static_cast<uint32_t>(packet.value);
    return true;
  case 9:
    settings.streetLineWidthBoost =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 0, 24));
    return true;
  case 10:
    settings.positionMarkerScale =
        static_cast<uint8_t>(clampValue<int32_t>(packet.value, 1, 5));
    return true;
  case 11:
    settings.tapToSwitchScreens = packet.value != 0 ? 1 : 0;
    return true;
  default:
    return false;
  }
}

} // namespace bike_ble
