#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "map_transfer.hpp"

namespace map_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string baseUrl;
  std::string apSsid;
  std::string lastErrorCode;
  std::string lastErrorMessage;
};

class MapTransferHttpServer {
public:
  void configure(std::string storageRoot = "/sdcard", uint16_t port = 8080);
  bool setEnabled(bool enabled);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;

private:
  std::string storageRoot_ = "/sdcard";
  uint16_t port_ = 8080;
  bool configured_ = false;
  bool enabled_ = false;
  bool startedAp_ = false;
  std::string apSsid_;
  WiFiServer server_{8080};
  MapTransferInstaller installer_{"/sdcard"};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  std::string lastErrorCode_;
  std::string lastErrorMessage_;
  bool activationRunning_ = false;
  std::string activationSessionId_;
  std::string activationStatus_ = "idle";
  std::string activationMapId_;
  std::string activationErrorCode_;
  std::string activationErrorMessage_;

  void handleClient(WiFiClient &client);
  bool handlePut(const std::string &path, uint64_t contentLength,
                 WiFiClient &client);
  bool handleHead(const std::string &path, WiFiClient &client);
  bool handleActivate(const std::string &path, WiFiClient &client);
  void handleStatus(WiFiClient &client);
  void sendHead(WiFiClient &client, int status, uint64_t contentLength = 0);
  void sendJson(WiFiClient &client, int status, const std::string &body);
  void sendError(WiFiClient &client, int status, const std::string &code,
                 const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
  void lockState() const;
  void unlockState() const;
  std::string activationStatusJson() const;
  void finishActivation(const std::string &status, const std::string &mapId,
                        const std::string &errorCode,
                        const std::string &errorMessage);
  void runActivationTask(const std::string &sessionId);
  static void activationTaskThunk(void *arg);
};

} // namespace map_transfer
