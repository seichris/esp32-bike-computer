#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <string>

namespace device_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string baseUrl;
  std::string apSsid;
  std::string lastErrorCode;
  std::string lastErrorMessage;
};

struct HttpRequest {
  std::string method;
  std::string path;
  uint64_t contentLength = 0;
};

class HttpRequestHandler {
public:
  virtual ~HttpRequestHandler() = default;
  virtual bool handleRequest(const HttpRequest &request,
                             WiFiClient &client) = 0;
};

class HttpTransferServer {
public:
  void configure(HttpRequestHandler *handler, uint16_t port = 8080,
                 std::string apSsid = "BikeComputer-Transfer");
  bool setEnabled(bool enabled);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;

private:
  HttpRequestHandler *handler_ = nullptr;
  uint16_t port_ = 8080;
  bool configured_ = false;
  bool enabled_ = false;
  bool startedAp_ = false;
  std::string apSsid_ = "BikeComputer-Transfer";
  WiFiServer server_{8080};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  std::string lastErrorCode_;
  std::string lastErrorMessage_;

  void handleClient(WiFiClient &client);
  void sendError(WiFiClient &client, int status, const std::string &code,
                 const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
  void lockState() const;
  void unlockState() const;
};

void sendHttpHead(WiFiClient &client, int status,
                  uint64_t contentLength = 0);
void sendHttpJson(WiFiClient &client, int status, const std::string &body);
void sendHttpError(WiFiClient &client, int status, const std::string &code,
                   const std::string &message);

} // namespace device_transfer
