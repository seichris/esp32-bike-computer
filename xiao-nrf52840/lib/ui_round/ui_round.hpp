#pragma once

#include <Arduino.h>

#include "ble_navigation.hpp"
#include "display_round.hpp"
#include "map_lite.hpp"
#include "power_manager.hpp"
#include "ui_round_core.hpp"

namespace xiao_round {

enum class RoundPage : uint8_t {
  Ride = 0,
  Navigation = 1,
  Route = 2,
  Settings = 3,
};

class RoundUi {
public:
  bool begin(DisplayRound &display);
  void update(BLENavigationServer &bleServer, PowerManager &powerManager,
              MapLite &mapLite);
  void nextPage();
  void previousPage();
  bool handleGesture(TouchGesture gesture, BLENavigationServer &bleServer,
                     PowerManager &powerManager);
  uint32_t lastInteractionMs() const { return lastTouchMs; }
  uint32_t lastRenderDurationMs() const { return renderDurationMs; }
  uint32_t maxRenderDurationMs() const { return maxRenderDurationMsValue; }
  bool isDenseMode() const { return denseMode; }

private:
  void handleTouchWake(BLENavigationServer &bleServer,
                       PowerManager &powerManager);
  void handleTouchInterrupt(const BLENavigationServer &bleServer);
  void drawRidePage(const BLENavigationServer &bleServer,
                    const PowerManager &powerManager);
  void drawNavigationPage(const BLENavigationServer &bleServer);
  void drawRoutePage(const BLENavigationServer &bleServer, MapLite &mapLite);
  void drawSettingsPage(const BLENavigationServer &bleServer,
                        const PowerManager &powerManager);
  uint16_t drawRoutePreview(const bike_ble::RouteSummary &route,
                            const bike_ble::GpsPosition &gps,
                            const BLEDebugStats &stats,
                            const bike_ble::MapRenderSettings &settings);
  uint16_t speedKmhX10(const bike_ble::GpsPosition &gps);
  uint16_t routeHeadingNearGps(const bike_ble::RouteSummary &route,
                               const bike_ble::GpsPosition &gps) const;
  const char *pageName() const;
  const char *gestureName(TouchGesture gesture) const;

  DisplayRound *display = nullptr;
  RoundPage page = RoundPage::Ride;
  uint32_t lastRenderMs = 0;
  uint32_t lastTouchMs = 0;
  bool lastTouchAsserted = false;
  bool touchActive = false;
  uint32_t touchStartMs = 0;
  int16_t touchStartX = 0;
  int16_t touchStartY = 0;
  int16_t touchLastX = 0;
  int16_t touchLastY = 0;
  bool haveSpeedReference = false;
  int32_t previousLatMicrodegrees = 0;
  int32_t previousLonMicrodegrees = 0;
  uint32_t previousUnixTime = 0;
  uint16_t derivedSpeedKmhX10 = 0;
  uint32_t renderDurationMs = 0;
  uint32_t maxRenderDurationMsValue = 0;
  bool denseMode = false;
};

} // namespace xiao_round
