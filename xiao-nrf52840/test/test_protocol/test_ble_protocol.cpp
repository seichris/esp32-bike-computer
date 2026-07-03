#include <unity.h>

#include "ble_protocol.hpp"

#include <cstring>
#include <vector>

namespace {

void writeI16(std::vector<uint8_t> &buffer, int16_t value) {
  const uint16_t bits = static_cast<uint16_t>(value);
  buffer.push_back(static_cast<uint8_t>(bits & 0xFF));
  buffer.push_back(static_cast<uint8_t>((bits >> 8) & 0xFF));
}

void writeU16(std::vector<uint8_t> &buffer, uint16_t value) {
  buffer.push_back(static_cast<uint8_t>(value & 0xFF));
  buffer.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
}

void writeI32(std::vector<uint8_t> &buffer, int32_t value) {
  const uint32_t bits = static_cast<uint32_t>(value);
  buffer.push_back(static_cast<uint8_t>(bits & 0xFF));
  buffer.push_back(static_cast<uint8_t>((bits >> 8) & 0xFF));
  buffer.push_back(static_cast<uint8_t>((bits >> 16) & 0xFF));
  buffer.push_back(static_cast<uint8_t>((bits >> 24) & 0xFF));
}

void writeU32(std::vector<uint8_t> &buffer, uint32_t value) {
  buffer.push_back(static_cast<uint8_t>(value & 0xFF));
  buffer.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
  buffer.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
  buffer.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
}

std::vector<uint8_t> routeWithPointCount(uint16_t points) {
  std::vector<uint8_t> route;
  route.reserve(8 + ((points - 1) * 4));
  writeI32(route, 1345000);
  writeI32(route, 103812000);
  for (uint16_t i = 1; i < points; i++) {
    writeI16(route, 10);
    writeI16(route, -5);
  }
  return route;
}

void testFramePrefixes() {
  const uint8_t route[] = {'M', 'A', 'P', 'R', 0x01};
  TEST_ASSERT_TRUE(bike_ble::hasFramePrefix(route, sizeof(route),
                                            bike_ble::FALLBACK_ROUTE_PREFIX));
  TEST_ASSERT_FALSE(bike_ble::hasFramePrefix(route, 3,
                                             bike_ble::FALLBACK_ROUTE_PREFIX));
  TEST_ASSERT_FALSE(bike_ble::hasFramePrefix(route, sizeof(route),
                                             bike_ble::FALLBACK_GPS_PREFIX));
}

void testNavigationParserBoundsAndCopiesInstruction() {
  bike_ble::NavigationData nav;
  const char payload[] = "300|70000|Turn left on River Valley Road";

  TEST_ASSERT_TRUE(bike_ble::parseNavigationData(
      reinterpret_cast<const uint8_t *>(payload), strlen(payload), nav));
  TEST_ASSERT_EQUAL_UINT8(255, nav.iconId);
  TEST_ASSERT_EQUAL_UINT16(65535, nav.distanceMeters);
  TEST_ASSERT_EQUAL_STRING("Turn left on River Valley Road", nav.instruction);

  const char invalid[] = "1|missing-distance";
  TEST_ASSERT_FALSE(bike_ble::parseNavigationData(
      reinterpret_cast<const uint8_t *>(invalid), strlen(invalid), nav));
}

void testGpsParserSupportsExtendedTelemetry() {
  std::vector<uint8_t> payload;
  writeI32(payload, 1345000);
  writeI32(payload, 103812000);
  writeU16(payload, 275);
  writeU32(payload, 1783080000);
  writeU16(payload, 765);
  writeI16(payload, 42);
  writeU32(payload, 12345);
  writeU32(payload, 987);
  writeU32(payload, 4321);

  bike_ble::GpsPosition gps;
  TEST_ASSERT_TRUE(
      bike_ble::parseGpsPosition(payload.data(), payload.size(), gps));
  TEST_ASSERT_EQUAL_INT32(1345000, gps.latMicrodegrees);
  TEST_ASSERT_EQUAL_INT32(103812000, gps.lonMicrodegrees);
  TEST_ASSERT_EQUAL_UINT16(275, gps.headingDegrees);
  TEST_ASSERT_TRUE(gps.hasUnixTime);
  TEST_ASSERT_EQUAL_UINT32(1783080000, gps.unixTime);
  TEST_ASSERT_TRUE(gps.hasSpeed);
  TEST_ASSERT_EQUAL_UINT16(765, gps.speedCmps);
  TEST_ASSERT_TRUE(gps.hasAltitude);
  TEST_ASSERT_EQUAL_INT16(42, gps.altitudeMeters);
  TEST_ASSERT_TRUE(gps.hasDistanceTraveled);
  TEST_ASSERT_EQUAL_UINT32(12345, gps.distanceTraveledMeters);
  TEST_ASSERT_TRUE(gps.hasElapsedTime);
  TEST_ASSERT_EQUAL_UINT32(987, gps.elapsedSeconds);
  TEST_ASSERT_TRUE(gps.hasRouteRemaining);
  TEST_ASSERT_EQUAL_UINT32(4321, gps.routeRemainingMeters);
}

void testGpsParserHonorsSentinels() {
  std::vector<uint8_t> payload;
  writeI32(payload, 1);
  writeI32(payload, 2);
  writeU16(payload, 0);
  writeU32(payload, 100);
  writeU16(payload, 0xFFFF);
  writeI16(payload, 0);
  writeU32(payload, 0);
  writeU32(payload, 0);
  writeU32(payload, 0xFFFFFFFF);

  bike_ble::GpsPosition gps;
  TEST_ASSERT_TRUE(
      bike_ble::parseGpsPosition(payload.data(), payload.size(), gps));
  TEST_ASSERT_FALSE(gps.hasSpeed);
  TEST_ASSERT_EQUAL_UINT16(0, gps.speedCmps);
  TEST_ASSERT_FALSE(gps.hasRouteRemaining);
  TEST_ASSERT_EQUAL_UINT32(0, gps.routeRemainingMeters);
}

void testGpsParserRejectsMalformedIntermediateLengths() {
  const uint8_t supportedLengths[] = {8, 10, 14, 16, 18, 22, 26, 30};
  std::vector<uint8_t> payload(30, 0);
  payload[0] = 1;
  payload[4] = 2;

  bike_ble::GpsPosition gps;
  for (uint8_t len : supportedLengths) {
    TEST_ASSERT_TRUE(bike_ble::parseGpsPosition(payload.data(), len, gps));
  }

  for (uint8_t len = 0; len <= payload.size(); len++) {
    bool supported = false;
    for (uint8_t supportedLen : supportedLengths) {
      supported = supported || len == supportedLen;
    }
    if (!supported) {
      TEST_ASSERT_FALSE(bike_ble::parseGpsPosition(payload.data(), len, gps));
    }
  }
}

void testRouteParserStoresBoundedPreview() {
  const std::vector<uint8_t> payload =
      routeWithPointCount(bike_ble::MAX_ROUTE_POINTS + 3);

  bike_ble::RouteSummary route;
  TEST_ASSERT_TRUE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), route));
  TEST_ASSERT_TRUE(route.loaded);
  TEST_ASSERT_TRUE(route.truncated);
  TEST_ASSERT_EQUAL_UINT16(bike_ble::MAX_ROUTE_POINTS + 3, route.pointCount);
  TEST_ASSERT_EQUAL_UINT16(bike_ble::MAX_ROUTE_POINTS, route.storedPointCount);
  TEST_ASSERT_EQUAL_INT32(1345000, route.startLatMicrodegrees);
  TEST_ASSERT_EQUAL_INT32(103812000, route.startLonMicrodegrees);
  TEST_ASSERT_EQUAL_INT32(1345000 + (10 * (route.pointCount - 1)),
                          route.endLatMicrodegrees);
  TEST_ASSERT_EQUAL_INT32(103812000 - (5 * (route.pointCount - 1)),
                          route.endLonMicrodegrees);
  TEST_ASSERT_TRUE(route.totalDistanceMeters > 0);
}

void testRouteParserComputesApproximateTotalDistance() {
  std::vector<uint8_t> payload;
  writeI32(payload, 0);
  writeI32(payload, 0);
  writeI16(payload, 1000);
  writeI16(payload, 0);
  writeI16(payload, 0);
  writeI16(payload, 1000);

  bike_ble::RouteSummary route;
  TEST_ASSERT_TRUE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), route));
  TEST_ASSERT_EQUAL_UINT16(3, route.pointCount);
  TEST_ASSERT_UINT32_WITHIN(2, 223, route.totalDistanceMeters);
}

void testRouteHashAndDuplicateDecisionUsePayloadAndLength() {
  std::vector<uint8_t> payload;
  writeI32(payload, 1000000);
  writeI32(payload, 2000000);
  writeI16(payload, 100);
  writeI16(payload, -50);

  bike_ble::RouteSummary first;
  bike_ble::RouteSummary second;
  TEST_ASSERT_TRUE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), first));
  TEST_ASSERT_TRUE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), second));
  TEST_ASSERT_NOT_EQUAL_UINT32(0, first.hash);
  TEST_ASSERT_EQUAL_UINT32(first.hash, second.hash);
  TEST_ASSERT_EQUAL_UINT16(payload.size(), first.lengthBytes);
  TEST_ASSERT_TRUE(
      bike_ble::isDuplicateRouteSummary(second, first.hash, first.lengthBytes));
  TEST_ASSERT_FALSE(
      bike_ble::isDuplicateRouteSummary(second, first.hash, first.lengthBytes + 1));

  payload.push_back(0);
  payload.push_back(0);
  payload.push_back(0);
  payload.push_back(0);
  bike_ble::RouteSummary longer;
  TEST_ASSERT_TRUE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), longer));
  TEST_ASSERT_FALSE(
      bike_ble::isDuplicateRouteSummary(longer, first.hash, first.lengthBytes));
  TEST_ASSERT_FALSE(bike_ble::isDuplicateRouteSummary(
      bike_ble::RouteSummary{}, first.hash, first.lengthBytes));
}

void testRouteParserRejectsMalformedPayloadsAndClearsOutput() {
  std::vector<uint8_t> payload;
  writeI32(payload, 1000000);
  writeI32(payload, 2000000);
  writeI16(payload, 100);

  bike_ble::RouteSummary route;
  route.loaded = true;
  TEST_ASSERT_FALSE(
      bike_ble::parseRouteGeometry(payload.data(), payload.size(), route));
  TEST_ASSERT_FALSE(route.loaded);
  TEST_ASSERT_EQUAL_UINT16(0, route.pointCount);
  TEST_ASSERT_EQUAL_UINT32(0, route.hash);

  TEST_ASSERT_FALSE(bike_ble::parseRouteGeometry(nullptr, 0, route));
  TEST_ASSERT_FALSE(route.loaded);
}

void testMapSettingsClampAndRejectUnknownIds() {
  bike_ble::MapRenderSettings settings;
  bike_ble::MapSettingPacket packet;
  const uint8_t zoom[] = {7, 99, 0, 0, 0};
  const uint8_t lineWidth[] = {3, 1, 0, 0, 0};
  const uint8_t unknown[] = {99, 1, 0, 0, 0};
  const uint8_t overlong[] = {7, 4, 0, 0, 0, 0};

  TEST_ASSERT_TRUE(bike_ble::parseMapSetting(zoom, sizeof(zoom), packet));
  TEST_ASSERT_TRUE(bike_ble::applyMapSetting(packet, settings));
  TEST_ASSERT_EQUAL_UINT8(5, settings.zoomLevel);

  TEST_ASSERT_TRUE(
      bike_ble::parseMapSetting(lineWidth, sizeof(lineWidth), packet));
  TEST_ASSERT_TRUE(bike_ble::applyMapSetting(packet, settings));
  TEST_ASSERT_EQUAL_UINT8(2, settings.routeLineWidth);

  TEST_ASSERT_TRUE(bike_ble::parseMapSetting(unknown, sizeof(unknown), packet));
  TEST_ASSERT_FALSE(bike_ble::applyMapSetting(packet, settings));
  TEST_ASSERT_FALSE(
      bike_ble::parseMapSetting(overlong, sizeof(overlong), packet));
}

} // namespace

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(testFramePrefixes);
  RUN_TEST(testNavigationParserBoundsAndCopiesInstruction);
  RUN_TEST(testGpsParserSupportsExtendedTelemetry);
  RUN_TEST(testGpsParserHonorsSentinels);
  RUN_TEST(testGpsParserRejectsMalformedIntermediateLengths);
  RUN_TEST(testRouteParserStoresBoundedPreview);
  RUN_TEST(testRouteParserComputesApproximateTotalDistance);
  RUN_TEST(testRouteHashAndDuplicateDecisionUsePayloadAndLength);
  RUN_TEST(testRouteParserRejectsMalformedPayloadsAndClearsOutput);
  RUN_TEST(testMapSettingsClampAndRejectUnknownIds);
  return UNITY_END();
}
