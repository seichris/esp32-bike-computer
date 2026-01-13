/**
 * @file ble_navigation.cpp
 * @brief BLE navigation server implementation
 *
 * Handles incoming navigation data from iOS app and triggers map updates.
 */

#include "ble_navigation.hpp"
#include "../gps/gps.hpp"
#include "../gui/src/waitingScr.hpp"
#include "../route_overlay/route_overlay.hpp"
#include <NimBLEDevice.h>
#include <Preferences.h>

extern Gps gps;

// Global instance
BLENavigationServer bleNavServer;

// Forward declaration of map redraw trigger
extern void triggerMapRedraw();

// NavigationData struct is now in ble_navigation.hpp

// Map rendering settings moved to header for external access
// Global map render settings (accessible from maps.cpp)
MapRenderSettings mapRenderSettings;

// NVS Preferences for persistent settings
static Preferences settingsPrefs;

// Global navigation data
static NavigationData currentNavData = {0, 0, ""};
static volatile bool navDataUpdated = false;

// Route geometry debouncing - skip redundant parses
static uint32_t lastRouteHash = 0;
static size_t lastRouteLen = 0;

/**
 * @brief Parse navigation instruction data
 */
static void parseNavigationData(const std::string &data) {
  // Format: "IconID|Distance|Instruction"
  int firstPipe = data.find('|');
  int secondPipe = data.find('|', firstPipe + 1);

  if (firstPipe == std::string::npos || secondPipe == std::string::npos) {
    Serial.println("BLE: Invalid navigation data format");
    return;
  }

  currentNavData.iconID = atoi(data.substr(0, firstPipe).c_str());
  currentNavData.distance =
      atoi(data.substr(firstPipe + 1, secondPipe - firstPipe - 1).c_str());

  std::string instruction = data.substr(secondPipe + 1);
  strncpy(currentNavData.instruction, instruction.c_str(),
          sizeof(currentNavData.instruction) - 1);
  currentNavData.instruction[sizeof(currentNavData.instruction) - 1] = '\0';

  navDataUpdated = true;

  Serial.printf("BLE Nav: Icon=%d, Dist=%dm, Instr=%s\n", currentNavData.iconID,
                currentNavData.distance, currentNavData.instruction);
}

// ============================================================================
// NimBLE Callbacks
// ============================================================================

class MyBLEServerCallbacks : public NimBLEServerCallbacks {
public:
  BLENavigationServer *server;

  MyBLEServerCallbacks(BLENavigationServer *srv) : server(srv) {}

  void onConnect(NimBLEServer *pServer) override {
    server->connected = true;
    Serial.println("BLE: iOS client connected!");
    // Stop advertising when connected
    NimBLEDevice::stopAdvertising();
  }

  void onDisconnect(NimBLEServer *pServer) override {
    server->connected = false;
    Serial.println("BLE: iOS client disconnected");
    // Restart advertising
    Serial.println("BLE: Restarting advertising...");
    NimBLEDevice::startAdvertising();
  }
};

class MyNavCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (value.length() > 0) {
      Serial.printf("BLE Nav received: %s\n", value.c_str());
      parseNavigationData(value);
    }
  }
};

class MyRouteCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (value.length() > 0) {
      // Debounce: compute simple hash and skip if identical to last route
      uint32_t hash = 0;
      const uint8_t *data = (const uint8_t *)value.data();
      for (size_t i = 0; i < value.length(); i++) {
        hash = hash * 31 + data[i];
      }

      if (hash == lastRouteHash && value.length() == lastRouteLen) {
        // Skip redundant route update
        return;
      }

      lastRouteHash = hash;
      lastRouteLen = value.length();

      Serial.printf("BLE Route geometry received: %d bytes\n", value.length());

      // Parse route data into the global route overlay
      routeOverlay.parseRouteData((const uint8_t *)value.data(),
                                  value.length());

      // Trigger map redraw to show the new route
      triggerMapRedraw();
    }
  }
};

class MyGPSCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (value.length() >= 8) {
      int32_t lat, lon;
      memcpy(&lat, value.data(), 4);
      memcpy(&lon, value.data() + 4, 4);

      gps.gpsData.latitude = (double)lat / 1000000.0;
      gps.gpsData.longitude = (double)lon / 1000000.0;
      gps.gpsData.fixMode = 3;     // Simulate active fix
      gps.gpsData.satellites = 10; // Fake sat count

      // Parse optional heading (2 bytes, uint16_t)
      if (value.length() >= 10) {
        uint16_t headingVal;
        memcpy(&headingVal, value.data() + 8, 2);
        gps.gpsData.heading = headingVal;
      }

      // If this is the first GPS received from app, trigger transition to map
      if (!gpsReceivedFromApp) {
        gpsReceivedFromApp = true;
        pendingTransitionToMap = true;
        Serial.println(
            "BLE GPS: First position received, transitioning to map...");
      }

      triggerMapRedraw();
    }
  }
};

/**
 * @brief Settings characteristic callback - receives runtime config from iOS
 * app Format: [settingId:1][value:4] = 5 bytes Setting IDs: 1=minPolygonSize,
 * 2=detailLevel, 3=routeLineWidth
 */
class MySettingsCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (value.length() >= 5) {
      uint8_t settingId = value[0];
      int32_t settingValue;
      memcpy(&settingValue, value.data() + 1, 4);

      switch (settingId) {
      case 1: // minPolygonSize
        mapRenderSettings.minPolygonSize =
            (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)50);
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("minPolySize", mapRenderSettings.minPolygonSize);
        settingsPrefs.end();
        Serial.printf("BLE Settings: minPolygonSize = %d (saved)\n",
                      mapRenderSettings.minPolygonSize);
        break;
      case 2: // detailLevel
        mapRenderSettings.detailLevel =
            (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)2);
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("detailLevel", mapRenderSettings.detailLevel);
        settingsPrefs.end();
        Serial.printf("BLE Settings: detailLevel = %d (saved)\n",
                      mapRenderSettings.detailLevel);
        break;
      case 3: // routeLineWidth
        mapRenderSettings.routeLineWidth =
            (uint8_t)std::min(std::max(settingValue, (int32_t)2), (int32_t)8);
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("routeWidth", mapRenderSettings.routeLineWidth);
        settingsPrefs.end();
        Serial.printf("BLE Settings: routeLineWidth = %d (saved)\n",
                      mapRenderSettings.routeLineWidth);
        break;
      case 4: // displayRotation (0-3, requires reboot to apply)
        mapRenderSettings.displayRotation =
            (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)3);
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("rotation", mapRenderSettings.displayRotation);
        settingsPrefs.end();
        Serial.printf("BLE Settings: displayRotation = %d (reboot to apply)\n",
                      mapRenderSettings.displayRotation);
        break;
      case 5: // Reboot command from iOS app
        Serial.println("BLE Settings: Reboot command received! Restarting...");
        delay(500); // Brief delay to allow BLE response
        ESP.restart();
        break;
      case 6: // mapRotationMode (0=North Up, 1=Course Up)
        mapRenderSettings.mapRotationMode =
            (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)1);
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("mapRotMode", mapRenderSettings.mapRotationMode);
        settingsPrefs.end();
        Serial.printf("BLE Settings: mapRotationMode = %d (saved)\n",
                      mapRenderSettings.mapRotationMode);
        break;
      case 7: { // zoomLevel (0-5: 0=super, 1=1.5x, 2=1x, 3-5=divided)
        extern uint8_t zoom; // Global zoom variable from settings.cpp
        mapRenderSettings.zoomLevel =
            (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)5);
        zoom = mapRenderSettings.zoomLevel; // Apply to global zoom
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUChar("zoomLevel", mapRenderSettings.zoomLevel);
        settingsPrefs.end();
        Serial.printf("BLE Settings: zoomLevel = %d (saved)\n",
                      mapRenderSettings.zoomLevel);
        break;
      }
      case 8: { // visibilityMask (bitmask for feature type visibility)
        mapRenderSettings.visibilityMask = (uint32_t)settingValue;
        // Save to NVS for persistence across reboots
        settingsPrefs.begin("mapSettings", false);
        settingsPrefs.putUInt("visMask", mapRenderSettings.visibilityMask);
        settingsPrefs.end();
        Serial.printf("BLE Settings: visibilityMask = 0x%08X (saved)\n",
                      mapRenderSettings.visibilityMask);
        break;
      }
      default:
        Serial.printf("BLE Settings: Unknown setting ID %d\n", settingId);
        break;
      }

      // Trigger map redraw to apply new settings
      triggerMapRedraw();
    }
  }
};

// ============================================================================
// BLE Navigation Server Implementation
// ============================================================================

/**
 * @brief Load all map settings from NVS at startup
 */
static void loadSettingsFromNVS() {
  Preferences prefs;
  prefs.begin("mapSettings", true); // read-only

  mapRenderSettings.minPolygonSize = prefs.getUChar("minPolySize", 0);
  mapRenderSettings.detailLevel = prefs.getUChar("detailLevel", 2);
  mapRenderSettings.routeLineWidth = prefs.getUChar("routeWidth", 4);
  mapRenderSettings.displayRotation = prefs.getUChar("rotation", 0);
  mapRenderSettings.mapRotationMode = prefs.getUChar("mapRotMode", 0);
  mapRenderSettings.zoomLevel = prefs.getUChar("zoomLevel", 4);
  mapRenderSettings.visibilityMask = prefs.getUInt("visMask", 0xFFFFFFFF);

  prefs.end();

  Serial.printf("BLE: Loaded settings from NVS - minPolySize=%d, "
                "detailLevel=%d, routeWidth=%d, rotation=%d\n",
                mapRenderSettings.minPolygonSize, mapRenderSettings.detailLevel,
                mapRenderSettings.routeLineWidth,
                mapRenderSettings.displayRotation);
}

void BLENavigationServer::init(const char *deviceName) {
  if (initialized) {
    Serial.println("BLE: Already initialized");
    return;
  }

  // Load persisted settings from NVS
  loadSettingsFromNVS();

  Serial.println("BLE: Initializing NimBLE server...");

  // Initialize NimBLE
  NimBLEDevice::init(deviceName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); // Maximum power
  NimBLEDevice::setMTU(512);              // Increase MTU for route geometry

  // Create server
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyBLEServerCallbacks(this));

  // Create Navigation Service (UUID 1819)
  NimBLEService *pService = pServer->createService(SERVICE_UUID);

  // Create Navigation Instruction Characteristic (UUID 2A6E)
  pNavCharacteristic = pService->createCharacteristic(
      NAV_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY // Added NOTIFY support just in case
  );
  pNavCharacteristic->setCallbacks(new MyNavCharacteristicCallbacks());

  pRouteCharacteristic = pService->createCharacteristic(
      ROUTE_CHAR_UUID, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  pRouteCharacteristic->setCallbacks(new MyRouteCharacteristicCallbacks());

  // Create GPS Position Characteristic (UUID 2A72)
  NimBLECharacteristic *pGPSCharacteristic =
      pService->createCharacteristic(GPS_CHAR_UUID, NIMBLE_PROPERTY::WRITE_NR);
  pGPSCharacteristic->setCallbacks(new MyGPSCharacteristicCallbacks());

  // Create Settings Characteristic (UUID 2A73) for runtime configuration
  NimBLECharacteristic *pSettingsCharacteristic =
      pService->createCharacteristic(SETTINGS_CHAR_UUID,
                                     NIMBLE_PROPERTY::WRITE_NR);
  pSettingsCharacteristic->setCallbacks(
      new MySettingsCharacteristicCallbacks());

  // Start service
  pService->start();

  // Start advertising
  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  initialized = true;
  Serial.printf("BLE: Server started, advertising as '%s'\n", deviceName);
}

void BLENavigationServer::process() {
  static uint32_t lastLog = 0;
  if (millis() - lastLog > 5000) {
    lastLog = millis();
    if (connected) {
      Serial.println("BLE Status: CONNECTED");
    } else {
      // Only log advertising status if NOT connected, to confirm it's still
      // alive
      if (initialized)
        Serial.println("BLE Status: ADVERTISING (Waiting for connection...)");
    }
  }
}

// ============================================================================
// Map Redraw Trigger (weak symbol - can be overridden by main app)
// ============================================================================

__attribute__((weak)) void triggerMapRedraw() {
  // Default implementation - will be overridden by mainScr.cpp
  Serial.println("BLE: triggerMapRedraw called (default - no map linked)");
}
