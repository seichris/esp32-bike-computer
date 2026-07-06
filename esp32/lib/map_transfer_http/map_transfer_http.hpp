#pragma once

#include <Arduino.h>
#include <WiFi.h>

#include "map_transfer.hpp"

namespace map_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string lastErrorCode;
  std::string lastErrorMessage;
};

class MapTransferHttpServer {
public:
  void configure(std::string storageRoot = "/sdcard", uint16_t port = 8080);
  bool setEnabled(bool enabled);
  void process();
  HttpTransferStatus status() const;

private:
  std::string storageRoot_ = "/sdcard";
  uint16_t port_ = 8080;
  bool configured_ = false;
  bool enabled_ = false;
  WiFiServer server_{8080};
  MapTransferInstaller installer_{"/sdcard"};
  std::string lastErrorCode_;
  std::string lastErrorMessage_;

  void handleClient(WiFiClient &client);
  bool handlePut(const std::string &path, uint64_t contentLength,
                 WiFiClient &client);
  bool handleActivate(const std::string &path, WiFiClient &client);
  void handleStatus(WiFiClient &client);
  void sendJson(WiFiClient &client, int status, const std::string &body);
  void sendError(WiFiClient &client, int status, const std::string &code,
                 const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
};

} // namespace map_transfer
