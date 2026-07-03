#include "ui_round.hpp"

#include "round_display_pins.hpp"
#include "rtc_pcf8563.hpp"

#include <math.h>
#include <stdio.h>
#include <string.h>

namespace xiao_round {
namespace {

constexpr uint32_t UI_RENDER_INTERVAL_MS = 1000;
constexpr uint32_t TOUCH_DEBOUNCE_MS = 450;
constexpr double METERS_PER_MICRODEGREE_LAT = 0.11132;
constexpr double ROUTE_PREVIEW_RADIUS_METERS = 500.0;
constexpr uint16_t ROUTE_PREVIEW_SEGMENT_BUDGET = 96;
constexpr uint16_t ROUTE_COLOR_RGB565 = 0x001F;
constexpr uint16_t POSITION_COLOR_RGB565 = 0xF800;
constexpr uint8_t BRIGHTNESS_GESTURE_STEP_PERCENT = 5;

double degreesToRadians(double degrees) { return degrees * 0.017453292519943295; }

uint16_t headingBetweenMicrodegrees(int32_t latA, int32_t lonA, int32_t latB,
                                    int32_t lonB) {
  const double lat1 = degreesToRadians(static_cast<double>(latA) / 1000000.0);
  const double lat2 = degreesToRadians(static_cast<double>(latB) / 1000000.0);
  const double deltaLon =
      degreesToRadians(static_cast<double>(lonB - lonA) / 1000000.0);
  const double y = sin(deltaLon) * cos(lat2);
  const double x = cos(lat1) * sin(lat2) -
                   sin(lat1) * cos(lat2) * cos(deltaLon);
  double degrees = atan2(y, x) * 57.29577951308232;
  if (degrees < 0) {
    degrees += 360.0;
  }
  return static_cast<uint16_t>(degrees + 0.5) % 360;
}

void copyLine(char *destination, size_t destinationSize, const char *source) {
  if (destination == nullptr || destinationSize == 0) {
    return;
  }
  if (source == nullptr) {
    source = "";
  }
  strncpy(destination, source, destinationSize - 1);
  destination[destinationSize - 1] = '\0';
}

bool gpsLooksValid(const bike_ble::GpsPosition &gps,
                   const BLEDebugStats &stats) {
  return stats.gpsPacketCount > 0 &&
         (gps.latMicrodegrees != 0 || gps.lonMicrodegrees != 0);
}

int16_t clampScreenCoord(int32_t value) {
  if (value < 0) {
    return 0;
  }
  if (value >= DisplayRound::width) {
    return DisplayRound::width - 1;
  }
  return static_cast<int16_t>(value);
}

int16_t routeOffsetToScreen(double meters, bool invert) {
  const double pixels =
      (meters / ROUTE_PREVIEW_RADIUS_METERS) * ((DisplayRound::width - 1) / 2.0);
  const double centered =
      ((DisplayRound::width - 1) / 2.0) + (invert ? -pixels : pixels);
  return clampScreenCoord(static_cast<int32_t>(centered + 0.5));
}

} // namespace

bool RoundUi::begin(DisplayRound &targetDisplay) {
  display = &targetDisplay;
  pinMode(pins::touchInt, INPUT_PULLUP);
  lastTouchAsserted = digitalRead(pins::touchInt) == LOW;
  lastRenderMs = 0;
  display->drawStatus("Ride", "Waiting for BLE");
  Serial.println("RoundUi: initialized");
  return true;
}

void RoundUi::update(BLENavigationServer &bleServer, PowerManager &powerManager,
                     MapLite &mapLite) {
  handleTouchWake(bleServer, powerManager);

  const uint32_t now = millis();
  if (display == nullptr || now - lastRenderMs < UI_RENDER_INTERVAL_MS) {
    return;
  }

  lastRenderMs = now;
  const uint32_t renderStartMs = millis();
  speedKmhX10(bleServer.currentGps());
  switch (page) {
  case RoundPage::Ride:
    drawRidePage(bleServer, powerManager);
    break;
  case RoundPage::Navigation:
    drawNavigationPage(bleServer);
    break;
  case RoundPage::Route:
    drawRoutePage(bleServer, mapLite);
    break;
  case RoundPage::Settings:
    drawSettingsPage(bleServer, powerManager);
    break;
  }
  renderDurationMs = millis() - renderStartMs;
  if (renderDurationMs > maxRenderDurationMsValue) {
    maxRenderDurationMsValue = renderDurationMs;
  }
}

void RoundUi::nextPage() {
  page = static_cast<RoundPage>((static_cast<uint8_t>(page) + 1) % 4);
  lastRenderMs = 0;
  Serial.print("RoundUi: page=");
  Serial.println(pageName());
}

void RoundUi::previousPage() {
  page = static_cast<RoundPage>((static_cast<uint8_t>(page) + 3) % 4);
  lastRenderMs = 0;
  Serial.print("RoundUi: page=");
  Serial.println(pageName());
}

bool RoundUi::handleGesture(TouchGesture gesture,
                            BLENavigationServer &bleServer,
                            PowerManager &powerManager) {
  lastTouchMs = millis();

  switch (gesture) {
  case TouchGesture::TapCenter:
    if (page == RoundPage::Settings) {
      const uint8_t nextRotation =
          bleServer.currentSettings().mapRotationMode == 0 ? 1 : 0;
      bleServer.applyLocalMapSetting(6, nextRotation, "touch");
      Serial.print("RoundUi: map rotation=");
      Serial.println(nextRotation == 0 ? "north-up" : "course-up");
    } else {
      denseMode = !denseMode;
      Serial.print("RoundUi: density=");
      Serial.println(denseMode ? "dense" : "normal");
    }
    lastRenderMs = 0;
    break;
  case TouchGesture::LongPress:
    if (page == RoundPage::Settings) {
      bleServer.requestBleReset("touch", true);
      Serial.println("RoundUi: BLE reconnect reset requested");
    } else {
      page = RoundPage::Settings;
      Serial.println("RoundUi: page=settings");
    }
    lastRenderMs = 0;
    break;
  case TouchGesture::SwipeLeft:
    nextPage();
    break;
  case TouchGesture::SwipeRight:
    previousPage();
    break;
  case TouchGesture::SwipeUp:
  case TouchGesture::SwipeDown:
    if (page != RoundPage::Settings) {
      Serial.print("RoundUi: ");
      Serial.print(gestureName(gesture));
      Serial.println(" ignored outside settings");
      return false;
    }
    {
      const int16_t direction =
          gesture == TouchGesture::SwipeUp ? BRIGHTNESS_GESTURE_STEP_PERCENT
                                           : -BRIGHTNESS_GESTURE_STEP_PERCENT;
      const int16_t nextBrightness =
          static_cast<int16_t>(powerManager.targetBrightness()) + direction;
      powerManager.setTargetBrightness(
          static_cast<uint8_t>(nextBrightness < 0 ? 0 : nextBrightness));
      lastRenderMs = 0;
    }
    break;
  }

  Serial.print("RoundUi: gesture=");
  Serial.println(gestureName(gesture));
  return true;
}

void RoundUi::handleTouchWake(BLENavigationServer &bleServer,
                              PowerManager &powerManager) {
  const bool touchAsserted = digitalRead(pins::touchInt) == LOW;
  const uint32_t now = millis();
  int16_t touchX = 0;
  int16_t touchY = 0;
  const bool hasTouchPoint =
      touchAsserted && display != nullptr && display->readTouch(touchX, touchY);

  if (hasTouchPoint) {
    if (!touchActive && now - lastTouchMs > TOUCH_DEBOUNCE_MS) {
      touchActive = true;
      touchStartMs = now;
      touchStartX = touchX;
      touchStartY = touchY;
      Serial.print("RoundUi: touch start x=");
      Serial.print(touchX);
      Serial.print(" y=");
      Serial.println(touchY);
    }
    if (touchActive) {
      touchLastX = touchX;
      touchLastY = touchY;
      lastTouchMs = now;
    }
  } else if (touchActive) {
    const uint32_t durationMs = now - touchStartMs;
    const int16_t deltaX = touchLastX - touchStartX;
    const int16_t deltaY = touchLastY - touchStartY;
    touchActive = false;
    handleGesture(ui_round_core::classifyTouchGesture(durationMs, deltaX,
                                                      deltaY),
                  bleServer, powerManager);
  } else if (touchAsserted && !lastTouchAsserted &&
             now - lastTouchMs > TOUCH_DEBOUNCE_MS) {
    handleTouchInterrupt(bleServer);
  }
  lastTouchAsserted = touchAsserted;
}

void RoundUi::handleTouchInterrupt(const BLENavigationServer &bleServer) {
  const uint32_t now = millis();
  const bike_ble::MapRenderSettings &settings = bleServer.currentSettings();
  const bool tapSwitchEnabled =
      !bleServer.hasReceivedTapSwitchSetting() ||
      settings.tapToSwitchScreens != 0;
  lastTouchMs = now;
  if (tapSwitchEnabled) {
    nextPage();
  } else {
    Serial.println("RoundUi: touch ignored, tap switching disabled");
  }
}

void RoundUi::drawRidePage(const BLENavigationServer &bleServer,
                           const PowerManager &powerManager) {
  const BLEDebugStats stats = bleServer.getDebugStats();
  const bike_ble::GpsPosition &gps = bleServer.currentGps();
  const BatteryStatus &battery = powerManager.battery();
  char line1[32];
  char line2[32];
  char batteryText[12];
  const uint16_t speed = speedKmhX10(gps);
  if (!battery.valid) {
    snprintf(batteryText, sizeof(batteryText), "--");
  } else if (battery.low) {
    snprintf(batteryText, sizeof(batteryText), "LOW %u%%", battery.percent);
  } else {
    snprintf(batteryText, sizeof(batteryText), "%u%%", battery.percent);
  }
  if (denseMode) {
    snprintf(line1, sizeof(line1), "Ride %u.%u H%u", speed / 10, speed % 10,
             gps.headingDegrees);
    snprintf(line2, sizeof(line2), "D%lu E%lu R%lu",
             gps.hasDistanceTraveled
                 ? static_cast<unsigned long>(gps.distanceTraveledMeters)
                 : 0UL,
             gps.hasElapsedTime ? static_cast<unsigned long>(gps.elapsedSeconds)
                                : 0UL,
             gps.hasRouteRemaining
                 ? static_cast<unsigned long>(gps.routeRemainingMeters)
                 : 0UL);
  } else {
    snprintf(line1, sizeof(line1), "Ride %u.%u km/h", speed / 10, speed % 10);
    snprintf(line2, sizeof(line2), "BLE %s GPS %s Bat %s",
             stats.authenticated ? "OK" : (stats.connected ? "LOCK" : "WAIT"),
             gpsLooksValid(gps, stats) ? "OK" : "WAIT", batteryText);
  }
  display->drawStatus(line1, line2);
}

void RoundUi::drawNavigationPage(const BLENavigationServer &bleServer) {
  const bike_ble::NavigationData &nav = bleServer.currentNavigation();
  const bike_ble::RouteSummary &route = bleServer.currentRoute();
  const bike_ble::GpsPosition &gps = bleServer.currentGps();
  char instruction[32];
  copyLine(instruction, sizeof(instruction),
           nav.instruction[0] == '\0' ? "No instruction" : nav.instruction);
  const int16_t progressPermille = ui_round_core::routeProgressPermille(
      route.totalDistanceMeters, gps.hasRouteRemaining,
      gps.routeRemainingMeters);
  display->drawNavigation(ui_round_core::classifyManeuverIcon(nav.iconId),
                          nav.distanceMeters, instruction, progressPermille);
}

void RoundUi::drawRoutePage(const BLENavigationServer &bleServer,
                            MapLite &mapLite) {
  const bike_ble::RouteSummary &route = bleServer.currentRoute();
  const bike_ble::GpsPosition &gps = bleServer.currentGps();
  const bike_ble::MapRenderSettings &settings = bleServer.currentSettings();
  const BLEDebugStats stats = bleServer.getDebugStats();
  bool mapRendered = false;
  uint16_t routeSegments = 0;
  if (display != nullptr) {
    const uint32_t frameStartMs = millis();
    display->beginMapFrame();
    mapRendered = mapLite.renderLastProbePreview(*display, frameStartMs);
    routeSegments = drawRoutePreview(route, gps, stats, settings);
    display->endMapFrame(mapRendered ? "route-map" : "route-preview",
                         millis() - frameStartMs);
  }
  char line1[32];
  char line2[32];
  const uint16_t routeHeading = routeHeadingNearGps(route, gps);
  snprintf(line1, sizeof(line1), "Route %u/%u seg%u", route.storedPointCount,
           route.pointCount, routeSegments);
  snprintf(line2, sizeof(line2), "Head %u rem %lu map%s %c", routeHeading,
           gps.hasRouteRemaining
               ? static_cast<unsigned long>(gps.routeRemainingMeters)
               : 0UL,
           mapRendered ? "Y" : "N",
           settings.mapRotationMode == 0 ? 'N' : 'C');
  display->drawStatus(line1, line2);
}

void RoundUi::drawSettingsPage(const BLENavigationServer &bleServer,
                               const PowerManager &powerManager) {
  const bike_ble::MapRenderSettings &settings = bleServer.currentSettings();
  const rtc::Status &rtcStatus = rtc::status();
  char line1[32];
  char line2[32];
  snprintf(line1, sizeof(line1), "Settings z%u rot%u %s",
           settings.zoomLevel, settings.mapRotationMode,
           denseMode ? "dense" : "normal");
  snprintf(line2, sizeof(line2), "B%u%% R%lums RTC%s/%s",
           powerManager.currentBrightness(),
           static_cast<unsigned long>(renderDurationMs),
           rtcStatus.present ? "OK" : "MISS",
           rtcStatus.timeValid ? rtc::sourceName(rtcStatus.source) : "WAIT");
  display->drawStatus(line1, line2);
}

uint16_t RoundUi::drawRoutePreview(const bike_ble::RouteSummary &route,
                                   const bike_ble::GpsPosition &gps,
                                   const BLEDebugStats &stats,
                                   const bike_ble::MapRenderSettings &settings) {
  if (display == nullptr || route.storedPointCount < 2) {
    return 0;
  }

  const bool centerOnGps = gpsLooksValid(gps, stats);
  const int32_t centerLat =
      centerOnGps ? gps.latMicrodegrees : route.points[0].latMicrodegrees;
  const int32_t centerLon =
      centerOnGps ? gps.lonMicrodegrees : route.points[0].lonMicrodegrees;
  const double cosLat =
      cos(degreesToRadians(static_cast<double>(centerLat) / 1000000.0));
  const bool courseUp = centerOnGps && settings.mapRotationMode != 0;
  uint16_t drawnSegments = 0;

  for (uint16_t i = 0; i + 1 < route.storedPointCount &&
                       drawnSegments < ROUTE_PREVIEW_SEGMENT_BUDGET;
       i++) {
    const bike_ble::RoutePoint &a = route.points[i];
    const bike_ble::RoutePoint &b = route.points[i + 1];
    double ax = static_cast<double>(a.lonMicrodegrees - centerLon) *
                METERS_PER_MICRODEGREE_LAT * cosLat;
    double ay = static_cast<double>(a.latMicrodegrees - centerLat) *
                METERS_PER_MICRODEGREE_LAT;
    double bx = static_cast<double>(b.lonMicrodegrees - centerLon) *
                METERS_PER_MICRODEGREE_LAT * cosLat;
    double by = static_cast<double>(b.latMicrodegrees - centerLat) *
                METERS_PER_MICRODEGREE_LAT;
    if (courseUp) {
      ui_round_core::rotateOffsetForHeading(ax, ay, gps.headingDegrees);
      ui_round_core::rotateOffsetForHeading(bx, by, gps.headingDegrees);
    }

    if ((fabs(ax) > ROUTE_PREVIEW_RADIUS_METERS &&
         fabs(bx) > ROUTE_PREVIEW_RADIUS_METERS &&
         ((ax < 0.0) == (bx < 0.0))) ||
        (fabs(ay) > ROUTE_PREVIEW_RADIUS_METERS &&
         fabs(by) > ROUTE_PREVIEW_RADIUS_METERS &&
         ((ay < 0.0) == (by < 0.0)))) {
      continue;
    }

    display->drawLine(routeOffsetToScreen(ax, false),
                      routeOffsetToScreen(ay, true),
                      routeOffsetToScreen(bx, false),
                      routeOffsetToScreen(by, true), ROUTE_COLOR_RGB565);
    drawnSegments++;
  }

  if (centerOnGps) {
    const int16_t center = DisplayRound::width / 2;
    display->drawLine(center - 4, center, center + 4, center,
                      POSITION_COLOR_RGB565);
    display->drawLine(center, center - 4, center, center + 4,
                      POSITION_COLOR_RGB565);
  }
  return drawnSegments;
}

uint16_t RoundUi::speedKmhX10(const bike_ble::GpsPosition &gps) {
  if (gps.hasSpeed) {
    return ui_round_core::speedKmhX10FromCmps(gps.speedCmps);
  }

  if (gps.hasUnixTime && gps.unixTime > previousUnixTime &&
      (gps.latMicrodegrees != 0 || gps.lonMicrodegrees != 0)) {
    if (haveSpeedReference) {
      const uint32_t deltaSeconds = gps.unixTime - previousUnixTime;
      if (deltaSeconds > 0 && deltaSeconds <= 30) {
        derivedSpeedKmhX10 = ui_round_core::speedKmhX10FromDelta(
            previousLatMicrodegrees, previousLonMicrodegrees,
            gps.latMicrodegrees, gps.lonMicrodegrees, deltaSeconds);
      }
    }
    previousLatMicrodegrees = gps.latMicrodegrees;
    previousLonMicrodegrees = gps.lonMicrodegrees;
    previousUnixTime = gps.unixTime;
    haveSpeedReference = true;
  }

  return derivedSpeedKmhX10;
}

uint16_t RoundUi::routeHeadingNearGps(const bike_ble::RouteSummary &route,
                                      const bike_ble::GpsPosition &gps) const {
  if (route.storedPointCount < 2 ||
      (gps.latMicrodegrees == 0 && gps.lonMicrodegrees == 0)) {
    return gps.headingDegrees;
  }

  double bestDistanceSq = 0.0;
  uint16_t bestSegment = 0;
  bool haveSegment = false;
  const double cosLat =
      cos(degreesToRadians(static_cast<double>(gps.latMicrodegrees) /
                           1000000.0));

  for (uint16_t i = 0; i + 1 < route.storedPointCount; i++) {
    const bike_ble::RoutePoint &a = route.points[i];
    const bike_ble::RoutePoint &b = route.points[i + 1];
    const double x1 =
        static_cast<double>(a.lonMicrodegrees - gps.lonMicrodegrees) * cosLat;
    const double y1 =
        static_cast<double>(a.latMicrodegrees - gps.latMicrodegrees);
    const double x2 =
        static_cast<double>(b.lonMicrodegrees - gps.lonMicrodegrees) * cosLat;
    const double y2 =
        static_cast<double>(b.latMicrodegrees - gps.latMicrodegrees);
    const double segmentX = x2 - x1;
    const double segmentY = y2 - y1;
    const double segmentLenSq = (segmentX * segmentX) + (segmentY * segmentY);
    if (segmentLenSq <= 0.0) {
      continue;
    }
    double t = -((x1 * segmentX) + (y1 * segmentY)) / segmentLenSq;
    if (t < 0.0) {
      t = 0.0;
    } else if (t > 1.0) {
      t = 1.0;
    }
    const double closestX = x1 + (segmentX * t);
    const double closestY = y1 + (segmentY * t);
    const double distanceSq = (closestX * closestX) + (closestY * closestY);
    if (!haveSegment || distanceSq < bestDistanceSq) {
      haveSegment = true;
      bestDistanceSq = distanceSq;
      bestSegment = i;
    }
  }

  if (!haveSegment) {
    return gps.headingDegrees;
  }

  return headingBetweenMicrodegrees(
      route.points[bestSegment].latMicrodegrees,
      route.points[bestSegment].lonMicrodegrees,
      route.points[bestSegment + 1].latMicrodegrees,
      route.points[bestSegment + 1].lonMicrodegrees);
}

const char *RoundUi::pageName() const {
  switch (page) {
  case RoundPage::Ride:
    return "ride";
  case RoundPage::Navigation:
    return "navigation";
  case RoundPage::Route:
    return "route";
  case RoundPage::Settings:
    return "settings";
  }
  return "unknown";
}

const char *RoundUi::gestureName(TouchGesture gesture) const {
  switch (gesture) {
  case TouchGesture::TapCenter:
    return "tap";
  case TouchGesture::LongPress:
    return "long";
  case TouchGesture::SwipeLeft:
    return "left";
  case TouchGesture::SwipeRight:
    return "right";
  case TouchGesture::SwipeUp:
    return "up";
  case TouchGesture::SwipeDown:
    return "down";
  }
  return "unknown";
}

} // namespace xiao_round
