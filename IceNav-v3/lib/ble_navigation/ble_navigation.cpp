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

extern Gps gps;

// Global instance
BLENavigationServer bleNavServer;

// Forward declaration of map redraw trigger
extern void triggerMapRedraw();

// Navigation data structure (matching iOS app format:
// "IconID|Distance|Instruction")
struct NavigationData {
  uint8_t iconID;
  uint16_t distance;
  char instruction[64];
};

// Global navigation data
static NavigationData currentNavData = {0, 0, ""};
static volatile bool navDataUpdated = false;

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

// ============================================================================
// BLE Navigation Server Implementation
// ============================================================================

void BLENavigationServer::init(const char *deviceName) {
  if (initialized) {
    Serial.println("BLE: Already initialized");
    return;
  }

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
