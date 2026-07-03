#pragma once

#include <Arduino.h>
#include <bluefruit.h>

#include "ble_protocol.hpp"

namespace xiao_round {

struct BLEDebugStats {
  bool initialized = false;
  bool connected = false;
  bool authenticated = false;
  uint32_t connectCount = 0;
  uint32_t disconnectCount = 0;
  uint32_t authChallengeCount = 0;
  uint32_t authSuccessCount = 0;
  uint32_t navPacketCount = 0;
  uint32_t routePacketCount = 0;
  uint32_t gpsPacketCount = 0;
  uint32_t settingsPacketCount = 0;
  uint32_t deviceCommandCount = 0;
  uint32_t rejectedUnauthenticatedCount = 0;
  uint32_t lastConnectMs = 0;
  uint32_t lastDisconnectMs = 0;
  uint32_t lastAuthChallengeMs = 0;
  uint32_t lastAuthSuccessMs = 0;
  uint32_t lastNavPacketMs = 0;
  uint32_t lastRoutePacketMs = 0;
  uint32_t lastGpsPacketMs = 0;
  uint32_t lastSettingsPacketMs = 0;
  uint32_t lastDeviceCommandMs = 0;
  uint32_t lastRejectedUnauthenticatedMs = 0;
};

class BLENavigationServer {
public:
  bool begin(const char *deviceName = "BikeComputer-XIAO");
  void process();

  bool isConnected() const { return connected || simulationSessionActive; }
  bool isAuthenticated() const {
    return authenticated || simulationSessionActive;
  }
  BLEDebugStats getDebugStats() const;

  const bike_ble::NavigationData &currentNavigation() const {
    return navigationData;
  }
  const bike_ble::RouteSummary &currentRoute() const { return routeSummary; }
  const bike_ble::GpsPosition &currentGps() const { return gpsPosition; }
  const bike_ble::MapRenderSettings &currentSettings() const {
    return settings;
  }
  bool hasReceivedTapSwitchSetting() const { return tapSwitchSettingReceived; }
  void setInitialSettings(const bike_ble::MapRenderSettings &initialSettings);
  bool hasUnpersistedSettings() const { return settingsDirty; }
  uint32_t lastSettingsChangeMs() const { return lastSettingsChangeMsValue; }
  void markSettingsPersisted() { settingsDirty = false; }
  bool takeBrightnessCommand(uint8_t &brightnessPercent);
  bool applyLocalMapSetting(uint8_t settingId, int32_t value,
                            const char *source);
  void requestLocalReboot(const char *source);
  void beginSimulationSession();
  void endSimulationSession();
  void injectNavigationWrite(const uint8_t *data, uint16_t len);
  void injectRouteWrite(const uint8_t *data, uint16_t len, const char *source);
  void injectGpsWrite(const uint8_t *data, uint16_t len, const char *source);
  void injectSettingsWrite(const uint8_t *data, uint16_t len,
                           const char *source);

private:
  bool requireAuthenticated(const char *payloadName);
  void handleConnect(uint16_t connHandle);
  void handleDisconnect(uint16_t connHandle, uint8_t reason);
  void handleAuthWrite(uint16_t connHandle, const uint8_t *data, uint16_t len);
  void handleNavWrite(const uint8_t *data, uint16_t len);
  void handleRouteWrite(const uint8_t *data, uint16_t len,
                        const char *source);
  void handleGpsWrite(const uint8_t *data, uint16_t len, const char *source);
  void handleSettingsWrite(const uint8_t *data, uint16_t len,
                           const char *source);
  void notifyAuth(uint16_t connHandle, const char *response);
  bool handleDeviceCommand(const bike_ble::MapSettingPacket &packet,
                           const char *source);
  void scheduleReboot(const char *source);
  void scheduleBrightness(uint8_t brightnessPercent, const char *source);
  void refreshStats();

  bool initialized = false;
  bool connected = false;
  bool authenticated = false;
  uint16_t activeConnHandle = BLE_CONN_HANDLE_INVALID;
  char pendingAuthNonce[33] = "";

  BLEService service = BLEService(BLEUuid(bike_ble::SERVICE_UUID));
  BLECharacteristic navCharacteristic =
      BLECharacteristic(BLEUuid(bike_ble::NAV_CHAR_UUID));
  BLECharacteristic routeCharacteristic =
      BLECharacteristic(BLEUuid(bike_ble::ROUTE_CHAR_UUID));
  BLECharacteristic gpsCharacteristic =
      BLECharacteristic(BLEUuid(bike_ble::GPS_CHAR_UUID));
  BLECharacteristic settingsCharacteristic =
      BLECharacteristic(BLEUuid(bike_ble::SETTINGS_CHAR_UUID));
  BLECharacteristic authCharacteristic =
      BLECharacteristic(BLEUuid(bike_ble::AUTH_CHAR_UUID));
  BLEDis deviceInfoService;

  bike_ble::NavigationData navigationData;
  bike_ble::RouteSummary routeSummary;
  bike_ble::GpsPosition gpsPosition;
  bike_ble::MapRenderSettings settings;
  BLEDebugStats stats;
  uint32_t lastStatusLogMs = 0;
  uint32_t lastRtcSyncMs = 0;
  uint32_t lastSettingsChangeMsValue = 0;
  uint32_t lastRouteHash = 0;
  uint32_t rebootAtMs = 0;
  uint16_t lastRouteLen = 0;
  uint8_t pendingBrightnessPercent = 0;
  bool settingsDirty = false;
  bool rebootPending = false;
  bool brightnessCommandPending = false;
  bool tapSwitchSettingReceived = false;
  bool simulationSessionActive = false;

  friend void onBleConnect(uint16_t connHandle);
  friend void onBleDisconnect(uint16_t connHandle, uint8_t reason);
  friend void onNavWrite(uint16_t connHandle, BLECharacteristic *chr,
                         uint8_t *data, uint16_t len);
  friend void onRouteWrite(uint16_t connHandle, BLECharacteristic *chr,
                           uint8_t *data, uint16_t len);
  friend void onGpsWrite(uint16_t connHandle, BLECharacteristic *chr,
                         uint8_t *data, uint16_t len);
  friend void onSettingsWrite(uint16_t connHandle, BLECharacteristic *chr,
                              uint8_t *data, uint16_t len);
  friend void onAuthWrite(uint16_t connHandle, BLECharacteristic *chr,
                          uint8_t *data, uint16_t len);
};

extern BLENavigationServer bleNavigationServer;

} // namespace xiao_round
