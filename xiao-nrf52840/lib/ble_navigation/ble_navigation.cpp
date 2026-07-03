#include "ble_navigation.hpp"

#include "rtc_pcf8563.hpp"

#include <Adafruit_nRFCrypto.h>
#include <ctype.h>
#include <string.h>

extern "C" {
#include "crys_hmac.h"
}

namespace xiao_round {
namespace {

constexpr uint16_t MAX_ROUTE_PACKET_BYTES = 512;
constexpr uint32_t UNAUTHENTICATED_TIMEOUT_MS = 12000;
constexpr uint32_t BLE_RTC_SYNC_INTERVAL_MS = 10UL * 60UL * 1000UL;
constexpr uint32_t REBOOT_DELAY_MS = 750;
constexpr char AUTH_KEY[] = "BikeComputer BLE v1 local pairing key";

BLENavigationServer *activeServer = nullptr;

bool isHexNonce(const char *nonce) {
  if (nonce == nullptr || strlen(nonce) != 32) {
    return false;
  }
  for (size_t i = 0; i < 32; i++) {
    if (!isxdigit(static_cast<unsigned char>(nonce[i]))) {
      return false;
    }
  }
  return true;
}

bool constantTimeEquals(const char *a, const char *b) {
  if (a == nullptr || b == nullptr) {
    return false;
  }
  const size_t aLen = strlen(a);
  const size_t bLen = strlen(b);
  if (aLen != bLen) {
    return false;
  }

  uint8_t diff = 0;
  for (size_t i = 0; i < aLen; i++) {
    diff |= static_cast<uint8_t>(a[i] ^ b[i]);
  }
  return diff == 0;
}

bool hmacSha256Hex(const char *message, char *outHex, size_t outHexSize) {
  if (message == nullptr || outHex == nullptr || outHexSize < 65) {
    return false;
  }

  CRYS_HASH_Result_t digest = {};
  const CRYSError_t result = CRYS_HMAC(
      CRYS_HASH_SHA256_mode, const_cast<uint8_t *>(
                                 reinterpret_cast<const uint8_t *>(AUTH_KEY)),
      strlen(AUTH_KEY),
      const_cast<uint8_t *>(reinterpret_cast<const uint8_t *>(message)),
      strlen(message), digest);

  if (result != CRYS_OK) {
    Serial.print("BLE: HMAC failed, code=");
    Serial.println(static_cast<uint32_t>(result));
    return false;
  }

  static constexpr char hex[] = "0123456789abcdef";
  const uint8_t *bytes = reinterpret_cast<const uint8_t *>(digest);
  for (size_t i = 0; i < 32; i++) {
    outHex[i * 2] = hex[(bytes[i] >> 4) & 0x0F];
    outHex[(i * 2) + 1] = hex[bytes[i] & 0x0F];
  }
  outHex[64] = '\0';
  return true;
}

void logPayloadPreview(const char *label, const uint8_t *data, uint16_t len) {
  char ascii[33];
  const uint16_t previewLen = len > 32 ? 32 : len;
  for (uint16_t i = 0; i < previewLen; i++) {
    const uint8_t byte = data[i];
    ascii[i] = byte >= 0x20 && byte <= 0x7E ? static_cast<char>(byte) : '.';
  }
  ascii[previewLen] = '\0';
  Serial.print("BLE: ");
  Serial.print(label == nullptr ? "payload" : label);
  Serial.print(" len=");
  Serial.print(len);
  Serial.print(" ascii='");
  Serial.print(ascii);
  Serial.println("'");
}

} // namespace

BLENavigationServer bleNavigationServer;

void BLENavigationServer::setInitialSettings(
    const bike_ble::MapRenderSettings &initialSettings) {
  settings = initialSettings;
}

bool BLENavigationServer::takeBrightnessCommand(uint8_t &brightnessPercent) {
  if (!brightnessCommandPending) {
    return false;
  }
  brightnessPercent = pendingBrightnessPercent;
  brightnessCommandPending = false;
  return true;
}

bool BLENavigationServer::applyLocalMapSetting(uint8_t settingId, int32_t value,
                                               const char *source) {
  bike_ble::MapSettingPacket packet;
  packet.id = settingId;
  packet.value = value;
  if (!bike_ble::applyMapSetting(packet, settings)) {
    Serial.print("BLE: local setting ignored id=");
    Serial.print(settingId);
    Serial.print(" value=");
    Serial.println(value);
    return false;
  }

  if (packet.id == 11) {
    tapSwitchSettingReceived = true;
  }
  settingsDirty = true;
  lastSettingsChangeMsValue = millis();
  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "local" : source);
  Serial.print(" local setting id=");
  Serial.print(packet.id);
  Serial.print(" value=");
  Serial.println(packet.value);
  return true;
}

void BLENavigationServer::requestLocalReboot(const char *source) {
  stats.deviceCommandCount++;
  stats.lastDeviceCommandMs = millis();
  scheduleReboot(source == nullptr ? "local" : source);
  refreshStats();
}

void BLENavigationServer::requestBleReset(const char *source, bool clearBonds) {
  const uint32_t now = millis();
  stats.deviceCommandCount++;
  stats.bleResetCount++;
  stats.lastDeviceCommandMs = now;
  stats.lastBleResetMs = stats.lastDeviceCommandMs;

  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "local" : source);
  Serial.print(" reset requested clear_bonds=");
  Serial.println(clearBonds);

  if (clearBonds) {
    Bluefruit.Periph.clearBonds();
  }

  if (simulationSessionActive) {
    simulationSessionActive = false;
    authenticated = false;
    pendingAuthNonce[0] = '\0';
    stats.disconnectCount++;
    stats.lastDisconnectMs = now;
    Serial.println("BLE: serial simulation session reset");
  }

  if (connected && activeConnHandle != BLE_CONN_HANDLE_INVALID) {
    Bluefruit.disconnect(activeConnHandle);
  } else if (!Bluefruit.Advertising.isRunning()) {
    Bluefruit.Advertising.start(0);
  }

  refreshStats();
}

void BLENavigationServer::beginSimulationSession() {
  if (!simulationSessionActive) {
    simulationSessionActive = true;
    stats.connectCount++;
    stats.authSuccessCount++;
    stats.lastConnectMs = millis();
    stats.lastAuthSuccessMs = stats.lastConnectMs;
    Serial.println("BLE: serial simulation session enabled");
  }
  refreshStats();
}

void BLENavigationServer::endSimulationSession() {
  if (simulationSessionActive) {
    simulationSessionActive = false;
    stats.disconnectCount++;
    stats.lastDisconnectMs = millis();
    Serial.println("BLE: serial simulation session disabled");
  }
  refreshStats();
}

void BLENavigationServer::injectNavigationWrite(const uint8_t *data,
                                                uint16_t len) {
  beginSimulationSession();
  handleNavWrite(data, len);
}

void BLENavigationServer::injectRouteWrite(const uint8_t *data, uint16_t len,
                                           const char *source) {
  beginSimulationSession();
  handleRouteWrite(data, len, source == nullptr ? "serial-sim" : source);
}

void BLENavigationServer::injectGpsWrite(const uint8_t *data, uint16_t len,
                                         const char *source) {
  beginSimulationSession();
  handleGpsWrite(data, len, source == nullptr ? "serial-sim" : source);
}

void BLENavigationServer::injectSettingsWrite(const uint8_t *data, uint16_t len,
                                              const char *source) {
  beginSimulationSession();
  handleSettingsWrite(data, len, source == nullptr ? "serial-sim" : source);
}

void onBleConnect(uint16_t connHandle) {
  if (activeServer != nullptr) {
    activeServer->handleConnect(connHandle);
  }
}

void onBleDisconnect(uint16_t connHandle, uint8_t reason) {
  if (activeServer != nullptr) {
    activeServer->handleDisconnect(connHandle, reason);
  }
}

void onNavWrite(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len) {
  if (activeServer != nullptr) {
    activeServer->handleNavWrite(data, len);
  }
}

void onRouteWrite(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len) {
  if (activeServer != nullptr) {
    activeServer->handleRouteWrite(data, len, "native");
  }
}

void onGpsWrite(uint16_t, BLECharacteristic *, uint8_t *data, uint16_t len) {
  if (activeServer != nullptr) {
    activeServer->handleGpsWrite(data, len, "native");
  }
}

void onSettingsWrite(uint16_t, BLECharacteristic *, uint8_t *data,
                     uint16_t len) {
  if (activeServer != nullptr) {
    activeServer->handleSettingsWrite(data, len, "native");
  }
}

void onAuthWrite(uint16_t connHandle, BLECharacteristic *, uint8_t *data,
                 uint16_t len) {
  if (activeServer != nullptr) {
    activeServer->handleAuthWrite(connHandle, data, len);
  }
}

bool BLENavigationServer::begin(const char *deviceName) {
  if (initialized) {
    return true;
  }

  if (!nRFCrypto.begin()) {
    Serial.println("BLE: nRFCrypto init failed");
    return false;
  }

  activeServer = this;
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin(1, 0);
  Bluefruit.setTxPower(4);
  Bluefruit.setName(deviceName == nullptr ? "BikeComputer-XIAO" : deviceName);
  Bluefruit.Periph.setConnectCallback(onBleConnect);
  Bluefruit.Periph.setDisconnectCallback(onBleDisconnect);

  deviceInfoService.setManufacturer("Open Bike Computer");
  deviceInfoService.setModel("XIAO nRF52840 Round");
  deviceInfoService.setHardwareRev("Seeed XIAO nRF52840 + Round Display");
  deviceInfoService.setSoftwareRev("xiao-round-display");
  deviceInfoService.begin();

  service.begin();

  navCharacteristic.setProperties(CHR_PROPS_WRITE_WO_RESP | CHR_PROPS_NOTIFY);
  navCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  navCharacteristic.setMaxLen(128);
  navCharacteristic.setWriteCallback(onNavWrite);
  navCharacteristic.begin();

  authCharacteristic.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP |
                                   CHR_PROPS_NOTIFY);
  authCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  authCharacteristic.setMaxLen(128);
  authCharacteristic.setWriteCallback(onAuthWrite);
  authCharacteristic.begin();
  authCharacteristic.write("LOCKED");

  routeCharacteristic.setProperties(CHR_PROPS_WRITE_WO_RESP | CHR_PROPS_NOTIFY);
  routeCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  routeCharacteristic.setMaxLen(MAX_ROUTE_PACKET_BYTES);
  routeCharacteristic.setWriteCallback(onRouteWrite);
  routeCharacteristic.begin();

  gpsCharacteristic.setProperties(CHR_PROPS_WRITE_WO_RESP);
  gpsCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  gpsCharacteristic.setMaxLen(30);
  gpsCharacteristic.setWriteCallback(onGpsWrite);
  gpsCharacteristic.begin();

  settingsCharacteristic.setProperties(CHR_PROPS_WRITE_WO_RESP);
  settingsCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  settingsCharacteristic.setMaxLen(5);
  settingsCharacteristic.setWriteCallback(onSettingsWrite);
  settingsCharacteristic.begin();

  Bluefruit.Advertising.addService(service);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);

  initialized = true;
  refreshStats();
  Serial.print("BLE: Server advertising as ");
  Serial.println(deviceName == nullptr ? "BikeComputer-XIAO" : deviceName);
  return true;
}

void BLENavigationServer::handleConnect(uint16_t connHandle) {
  connected = true;
  authenticated = false;
  activeConnHandle = connHandle;
  pendingAuthNonce[0] = '\0';
  stats.connectCount++;
  stats.lastConnectMs = millis();
  refreshStats();
  Serial.println("BLE: iOS client connected");
}

void BLENavigationServer::handleDisconnect(uint16_t, uint8_t reason) {
  connected = false;
  authenticated = false;
  activeConnHandle = BLE_CONN_HANDLE_INVALID;
  pendingAuthNonce[0] = '\0';
  stats.disconnectCount++;
  stats.lastDisconnectMs = millis();
  refreshStats();
  Serial.print("BLE: client disconnected, reason=");
  Serial.println(reason);
}

bool BLENavigationServer::requireAuthenticated(const char *payloadName) {
  if (authenticated || simulationSessionActive) {
    return true;
  }
  stats.rejectedUnauthenticatedCount++;
  stats.lastRejectedUnauthenticatedMs = millis();
  refreshStats();
  Serial.print("BLE: rejected unauthenticated ");
  Serial.println(payloadName == nullptr ? "payload" : payloadName);
  return false;
}

void BLENavigationServer::handleAuthWrite(uint16_t connHandle,
                                          const uint8_t *data, uint16_t len) {
  if (data == nullptr || len == 0) {
    return;
  }
  if (len == 2 && ((data[0] == 0x01 && data[1] == 0x00) ||
                   (data[0] == 0x00 && data[1] == 0x00))) {
    return;
  }
  if (len > 128) {
    logPayloadPreview("rejected auth payload", data, len);
    return;
  }

  char payload[129];
  memcpy(payload, data, len);
  payload[len] = '\0';

  char *command = strtok(payload, "|");
  char *nonce = strtok(nullptr, "|");
  char *proof = strtok(nullptr, "|");
  char *extra = strtok(nullptr, "|");

  if (command == nullptr || nonce == nullptr || extra != nullptr ||
      !isHexNonce(nonce)) {
    logPayloadPreview("invalid auth payload", data, len);
    return;
  }

  if (strcmp(command, "HELLO") == 0 && proof == nullptr) {
    char message[48];
    char mac[65];
    char response[112];
    authenticated = false;
    snprintf(message, sizeof(message), "server|%s", nonce);
    if (!hmacSha256Hex(message, mac, sizeof(mac))) {
      return;
    }
    strncpy(pendingAuthNonce, nonce, sizeof(pendingAuthNonce) - 1);
    pendingAuthNonce[sizeof(pendingAuthNonce) - 1] = '\0';
    snprintf(response, sizeof(response), "SERVER|%s|%s", nonce, mac);
    notifyAuth(connHandle, response);
    stats.authChallengeCount++;
    stats.lastAuthChallengeMs = millis();
    refreshStats();
    Serial.println("BLE: auth challenge answered");
    return;
  }

  if (strcmp(command, "CLIENT") == 0 && proof != nullptr) {
    char message[48];
    char expected[65];
    if (!constantTimeEquals(nonce, pendingAuthNonce)) {
      Serial.println("BLE: rejected auth proof: nonce mismatch");
      return;
    }
    snprintf(message, sizeof(message), "client|%s", nonce);
    if (!hmacSha256Hex(message, expected, sizeof(expected))) {
      return;
    }
    if (!constantTimeEquals(proof, expected)) {
      Serial.println("BLE: rejected auth proof: invalid MAC");
      return;
    }

    authenticated = true;
    pendingAuthNonce[0] = '\0';
    char response[40];
    snprintf(response, sizeof(response), "OK|%s", nonce);
    notifyAuth(connHandle, response);
    stats.authSuccessCount++;
    stats.lastAuthSuccessMs = millis();
    refreshStats();
    Serial.println("BLE: session authenticated");
    return;
  }

  logPayloadPreview("unknown auth payload", data, len);
}

void BLENavigationServer::handleNavWrite(const uint8_t *data, uint16_t len) {
  if (bike_ble::hasFramePrefix(data, len, bike_ble::FALLBACK_ROUTE_PREFIX)) {
    handleRouteWrite(data + 4, len - 4, "fallback");
    return;
  }
  if (bike_ble::hasFramePrefix(data, len, bike_ble::FALLBACK_GPS_PREFIX)) {
    handleGpsWrite(data + 4, len - 4, "fallback");
    return;
  }
  if (bike_ble::hasFramePrefix(data, len, bike_ble::FALLBACK_SETTINGS_PREFIX)) {
    handleSettingsWrite(data + 4, len - 4, "fallback");
    return;
  }

  if (!requireAuthenticated("navigation instruction")) {
    return;
  }
  if (!bike_ble::parseNavigationData(data, len, navigationData)) {
    logPayloadPreview("invalid navigation payload", data, len);
    return;
  }

  stats.navPacketCount++;
  stats.lastNavPacketMs = millis();
  refreshStats();
  Serial.print("BLE Nav: icon=");
  Serial.print(navigationData.iconId);
  Serial.print(" distance=");
  Serial.print(navigationData.distanceMeters);
  Serial.print(" instruction=");
  Serial.println(navigationData.instruction);
}

void BLENavigationServer::handleRouteWrite(const uint8_t *data, uint16_t len,
                                           const char *source) {
  if (!requireAuthenticated("route geometry")) {
    return;
  }
  if (len > MAX_ROUTE_PACKET_BYTES) {
    Serial.println("BLE: rejected route geometry: packet too large");
    return;
  }
  if (len == 0) {
    routeSummary = bike_ble::RouteSummary{};
    lastRouteHash = 0;
    lastRouteLen = 0;
    stats.routePacketCount++;
    stats.lastRoutePacketMs = millis();
    refreshStats();
    Serial.print("BLE: ");
    Serial.print(source == nullptr ? "unknown" : source);
    Serial.println(" route cleared");
    return;
  }

  bike_ble::RouteSummary summary;
  if (!bike_ble::parseRouteGeometry(data, len, summary)) {
    Serial.println("BLE: rejected route geometry: malformed packet");
    return;
  }
  if (summary.hash == lastRouteHash && summary.lengthBytes == lastRouteLen) {
    return;
  }

  routeSummary = summary;
  lastRouteHash = routeSummary.hash;
  lastRouteLen = routeSummary.lengthBytes;
  stats.routePacketCount++;
  stats.lastRoutePacketMs = millis();
  refreshStats();
  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "unknown" : source);
  Serial.print(" route bytes=");
  Serial.print(routeSummary.lengthBytes);
  Serial.print(" points=");
  Serial.print(routeSummary.pointCount);
  Serial.print(" stored=");
  Serial.print(routeSummary.storedPointCount);
  Serial.print(" truncated=");
  Serial.println(routeSummary.truncated);
}

void BLENavigationServer::handleGpsWrite(const uint8_t *data, uint16_t len,
                                         const char *source) {
  if (!requireAuthenticated("GPS position")) {
    return;
  }
  if (!bike_ble::parseGpsPosition(data, len, gpsPosition)) {
    Serial.println("BLE: rejected GPS position");
    return;
  }

  stats.gpsPacketCount++;
  stats.lastGpsPacketMs = millis();
  refreshStats();

  bool rtcTimestampSynced = false;
  if (gpsPosition.hasUnixTime) {
    const uint32_t now = millis();
    const rtc::Status &rtcStatus = rtc::status();
    if (!rtcStatus.timeValid || lastRtcSyncMs == 0 ||
        now - lastRtcSyncMs >= BLE_RTC_SYNC_INTERVAL_MS) {
      rtcTimestampSynced = rtc::syncFromUnixTime(gpsPosition.unixTime, source);
      if (rtcTimestampSynced) {
        lastRtcSyncMs = now;
      }
    }
  }

  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "unknown" : source);
  Serial.print(" GPS lat=");
  Serial.print(gpsPosition.latMicrodegrees);
  Serial.print(" lon=");
  Serial.print(gpsPosition.lonMicrodegrees);
  Serial.print(" heading=");
  Serial.print(gpsPosition.headingDegrees);
  Serial.print(" rtcSync=");
  Serial.println(rtcTimestampSynced);
}

void BLENavigationServer::handleSettingsWrite(const uint8_t *data, uint16_t len,
                                              const char *source) {
  if (!requireAuthenticated("map setting")) {
    return;
  }

  bike_ble::MapSettingPacket packet;
  if (!bike_ble::parseMapSetting(data, len, packet)) {
    Serial.println("BLE: rejected map setting");
    return;
  }

  const bool handledCommand = handleDeviceCommand(packet, source);
  const bool knownSetting =
      handledCommand ? false : bike_ble::applyMapSetting(packet, settings);
  if (knownSetting) {
    if (packet.id == 11) {
      tapSwitchSettingReceived = true;
    }
    settingsDirty = true;
    lastSettingsChangeMsValue = millis();
  }
  stats.settingsPacketCount++;
  stats.lastSettingsPacketMs = millis();
  refreshStats();
  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "unknown" : source);
  Serial.print(" setting id=");
  Serial.print(packet.id);
  Serial.print(" value=");
  Serial.print(packet.value);
  Serial.print(handledCommand ? " command"
                              : (knownSetting ? " applied" : " ignored"));
  Serial.println();
}

void BLENavigationServer::notifyAuth(uint16_t connHandle,
                                     const char *response) {
  if (response == nullptr) {
    return;
  }
  authCharacteristic.write(response);
  authCharacteristic.notify(connHandle, response);
}

void BLENavigationServer::process() {
  const uint32_t now = millis();
  if (rebootPending && static_cast<int32_t>(now - rebootAtMs) >= 0) {
    Serial.println("BLE: rebooting now");
    delay(10);
    NVIC_SystemReset();
  }

  if (connected && !authenticated && stats.lastConnectMs != 0 &&
      now - stats.lastConnectMs > UNAUTHENTICATED_TIMEOUT_MS) {
    Serial.println("BLE: disconnecting unauthenticated client after timeout");
    Bluefruit.disconnect(activeConnHandle);
    stats.lastConnectMs = now;
  }

  if (now - lastStatusLogMs >= 5000) {
    lastStatusLogMs = now;
    refreshStats();
    Serial.print("BLE Status: init=");
    Serial.print(stats.initialized);
    Serial.print(" conn=");
    Serial.print(stats.connected);
    Serial.print(" auth=");
    Serial.print(stats.authenticated);
    Serial.print(" nav=");
    Serial.print(stats.navPacketCount);
    Serial.print(" route=");
    Serial.print(stats.routePacketCount);
    Serial.print(" gps=");
    Serial.print(stats.gpsPacketCount);
    Serial.print(" settings=");
    Serial.print(stats.settingsPacketCount);
    Serial.print(" commands=");
    Serial.print(stats.deviceCommandCount);
    Serial.print(" rejected=");
    Serial.println(stats.rejectedUnauthenticatedCount);
  }
}

BLEDebugStats BLENavigationServer::getDebugStats() const { return stats; }

void BLENavigationServer::refreshStats() {
  stats.initialized = initialized;
  stats.connected = connected || simulationSessionActive;
  stats.authenticated = authenticated || simulationSessionActive;
}

bool BLENavigationServer::handleDeviceCommand(
    const bike_ble::MapSettingPacket &packet, const char *source) {
  if (packet.id != 5 && packet.id != 12) {
    return false;
  }
  stats.deviceCommandCount++;
  stats.lastDeviceCommandMs = millis();
  switch (packet.id) {
  case 5:
    if (packet.value == 1) {
      scheduleReboot(source);
    } else {
      Serial.print("BLE: ignored device command id=5 value=");
      Serial.println(packet.value);
    }
    break;
  case 12:
    if (packet.value >= 5 && packet.value <= 100) {
      scheduleBrightness(static_cast<uint8_t>(packet.value), source);
    } else {
      Serial.print("BLE: ignored brightness command value=");
      Serial.println(packet.value);
    }
    break;
  default:
    break;
  }
  refreshStats();
  return true;
}

void BLENavigationServer::scheduleReboot(const char *source) {
  if (rebootPending) {
    return;
  }
  rebootPending = true;
  rebootAtMs = millis() + REBOOT_DELAY_MS;
  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "unknown" : source);
  Serial.print(" reboot scheduled in ms=");
  Serial.println(REBOOT_DELAY_MS);
}

void BLENavigationServer::scheduleBrightness(uint8_t brightnessPercent,
                                             const char *source) {
  pendingBrightnessPercent = brightnessPercent;
  brightnessCommandPending = true;
  Serial.print("BLE: ");
  Serial.print(source == nullptr ? "unknown" : source);
  Serial.print(" brightness command=");
  Serial.println(pendingBrightnessPercent);
}

} // namespace xiao_round
