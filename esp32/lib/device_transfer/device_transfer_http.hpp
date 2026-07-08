#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <array>
#include <string>

namespace device_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string mode;
  std::string baseUrl;
  std::string apSsid;
  std::string sessionToken;
  std::string lastErrorCode;
  std::string lastErrorMessage;
};

struct HttpRequest {
  std::string method;
  std::string path;
  std::string transferToken;
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
  void configure(uint16_t port = 8080,
                 std::string apSsid = "BikeComputer-Transfer");
  void configure(HttpRequestHandler *handler, uint16_t port = 8080,
                 std::string apSsid = "BikeComputer-Transfer");
  bool registerHandler(std::string pathPrefix, HttpRequestHandler *handler);
  bool setEnabled(bool enabled);
  bool setEnabled(bool enabled, std::string mode);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;
  bool isRequestAuthorized(const HttpRequest &request) const;

private:
  uint16_t port_ = 8080;
  bool configured_ = false;
  bool enabled_ = false;
  bool startedAp_ = false;
  std::string mode_;
  std::string apSsid_ = "BikeComputer-Transfer";
  std::string sessionToken_;
  WiFiServer server_{8080};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  std::string lastErrorCode_;
  std::string lastErrorMessage_;
  struct HandlerRegistration {
    std::string pathPrefix;
    HttpRequestHandler *handler = nullptr;
  };
  std::array<HandlerRegistration, 4> handlers_{};
  size_t handlerCount_ = 0;

  void handleClient(WiFiClient &client);
  HttpRequestHandler *handlerForPath(const std::string &path) const;
  std::string generateSessionToken() const;
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
bool readHttpBody(WiFiClient &client, uint64_t contentLength,
                  uint64_t maxLength, std::string &body,
                  uint32_t timeoutMs = 5000);

} // namespace device_transfer
