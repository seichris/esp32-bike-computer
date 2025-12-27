#pragma once

/**
 * @file ble_navigation.hpp
 * @brief BLE navigation server for iOS app communication
 *
 * Implements NimBLE server with two characteristics:
 * - 2A6E: Navigation instructions (text format)
 * - 2A6F: Route geometry (binary compressed format)
 */

#include <Arduino.h>

// Forward declarations - actual NimBLE includes only in .cpp
class NimBLEServer;
class NimBLECharacteristic;

/**
 * @brief BLE Navigation Server
 */
class BLENavigationServer {
public:
  BLENavigationServer() = default;

  /**
   * @brief Initialize the BLE server
   * @param deviceName Name to advertise as
   */
  void init(const char *deviceName = "IceNav-Bike");

  /**
   * @brief Check if a client is connected
   */
  bool isConnected() const { return connected; }

  /**
   * @brief Process any pending BLE events (call from main loop)
   */
  void process();

private:
  bool initialized = false;
  bool connected = false;

  // BLE UUIDs (matching iOS app)
  static constexpr const char *SERVICE_UUID = "1819";
  static constexpr const char *NAV_CHAR_UUID =
      "2A6E"; // Navigation instructions
  static constexpr const char *ROUTE_CHAR_UUID = "2A6F"; // Route geometry
  static constexpr const char *GPS_CHAR_UUID =
      "2A72"; // GPS Position (Location and Speed)

  NimBLEServer *pServer = nullptr;
  NimBLECharacteristic *pNavCharacteristic = nullptr;
  NimBLECharacteristic *pRouteCharacteristic = nullptr;

  friend class MyBLEServerCallbacks;
  friend class MyNavCharacteristicCallbacks;
  friend class MyRouteCharacteristicCallbacks;
};

// Global BLE server instance
extern BLENavigationServer bleNavServer;
