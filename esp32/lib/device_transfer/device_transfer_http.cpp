#include "device_transfer_http.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <esp_system.h>
#include <sstream>

namespace device_transfer {
namespace {

static std::string trim(const std::string &value) {
  size_t begin = 0;
  while (begin < value.size() &&
         std::isspace(static_cast<unsigned char>(value[begin]))) {
    begin++;
  }
  size_t end = value.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    end--;
  }
  return value.substr(begin, end - begin);
}

static std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

static bool readLine(WiFiClient &client, std::string &line,
                     uint32_t timeoutMs = 2000) {
  line.clear();
  uint32_t started = millis();
  while (millis() - started < timeoutMs) {
    while (client.available()) {
      char c = static_cast<char>(client.read());
      if (c == '\r')
        continue;
      if (c == '\n')
        return true;
      if (line.size() < 512)
        line.push_back(c);
    }
    delay(1);
  }
  return false;
}

static std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out.push_back(c);
    }
  }
  return out;
}

} // namespace

void HttpTransferServer::configure(HttpRequestHandler *handler, uint16_t port,
                                   std::string apSsid) {
  configure(port, std::move(apSsid));
  registerHandler("/", handler);
}

void HttpTransferServer::configure(uint16_t port, std::string apSsid) {
  port_ = port;
  if (!apSsid.empty())
    apSsid_ = std::move(apSsid);
  server_ = WiFiServer(port_);
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutex();
  configured_ = true;
}

bool HttpTransferServer::registerHandler(std::string pathPrefix,
                                         HttpRequestHandler *handler) {
  if (handler == nullptr || pathPrefix.empty())
    return false;
  for (size_t i = 0; i < handlerCount_; ++i) {
    if (handlers_[i].pathPrefix == pathPrefix) {
      handlers_[i].handler = handler;
      return true;
    }
  }
  if (handlerCount_ >= handlers_.size())
    return false;
  handlers_[handlerCount_++] = {std::move(pathPrefix), handler};
  return true;
}

bool HttpTransferServer::setEnabled(bool enabled) {
  return setEnabled(enabled, enabled ? mode_ : "");
}

bool HttpTransferServer::setEnabled(bool enabled, std::string mode) {
  lockState();
  const bool configured = configured_;
  const bool wasEnabled = enabled_;
  const bool wasStartedAp = startedAp_;
  const std::string previousMode = mode_;
  const std::string previousSessionToken = sessionToken_;
  const std::string apSsid = apSsid_;
  unlockState();

  if (!configured || handlerCount_ == 0) {
    lockState();
    rememberError("not_configured", "device transfer server is not configured");
    unlockState();
    return false;
  }

  if (enabled && !wasEnabled) {
    if (WiFi.status() != WL_CONNECTED) {
      WiFi.mode(WIFI_AP);
      if (!WiFi.softAP(apSsid.c_str())) {
        lockState();
        rememberError("wifi_ap", "could not start transfer Wi-Fi");
        unlockState();
        return false;
      }
      lockState();
      startedAp_ = true;
      unlockState();
      Serial.printf("DEVICE_TRANSFER_HTTP: started AP ssid=%s ip=%s\n",
                    apSsid.c_str(), WiFi.softAPIP().toString().c_str());
    }
    server_.begin();
    server_.setNoDelay(true);
  }
  if (!enabled && wasEnabled) {
    server_.stop();
    if (wasStartedAp) {
      WiFi.softAPdisconnect(true);
      WiFi.mode(WIFI_OFF);
      lockState();
      startedAp_ = false;
      unlockState();
    }
  }
  lockState();
  enabled_ = enabled;
  mode_ = enabled ? std::move(mode) : "";
  if (enabled) {
    if (!wasEnabled || previousMode != mode_ || previousSessionToken.empty()) {
      sessionToken_ = generateSessionToken();
    }
  } else {
    sessionToken_.clear();
  }
  unlockState();
  return true;
}

void HttpTransferServer::setLastError(const std::string &code,
                                      const std::string &message) {
  lockState();
  rememberError(code, message);
  unlockState();
}

void HttpTransferServer::process() {
  if (!enabled_)
    return;
  WiFiClient client = server_.accept();
  if (!client)
    return;
  handleClient(client);
  client.stop();
}

HttpTransferStatus HttpTransferServer::status() const {
  lockState();
  const bool configured = configured_;
  const bool enabled = enabled_;
  const bool startedAp = startedAp_;
  const uint16_t port = port_;
  const std::string mode = mode_;
  const std::string apSsid = apSsid_;
  const std::string sessionToken = sessionToken_;
  const std::string lastErrorCode = lastErrorCode_;
  const std::string lastErrorMessage = lastErrorMessage_;
  unlockState();

  std::string baseUrl;
  if (enabled) {
    IPAddress ip =
        startedAp ? WiFi.softAPIP() : (WiFi.status() == WL_CONNECTED
                                           ? WiFi.localIP()
                                           : IPAddress());
    if (ip != IPAddress()) {
      baseUrl = std::string("http://") + ip.toString().c_str() + ":" +
                std::to_string(port);
    }
  }
  return {configured,       enabled, port,     mode,
          baseUrl,          startedAp ? apSsid : "",
          sessionToken,     lastErrorCode,
          lastErrorMessage};
}

bool HttpTransferServer::isRequestAuthorized(
    const HttpRequest &request) const {
  lockState();
  const std::string sessionToken = sessionToken_;
  unlockState();
  return !sessionToken.empty() && request.transferToken == sessionToken;
}

void HttpTransferServer::handleClient(WiFiClient &client) {
  std::string requestLine;
  if (!readLine(client, requestLine)) {
    sendError(client, 408, "timeout", "request timed out");
    return;
  }

  HttpRequest request;
  std::stringstream requestStream(requestLine);
  std::string version;
  requestStream >> request.method >> request.path >> version;
  if (request.method.empty() || request.path.empty()) {
    sendError(client, 400, "bad_request", "invalid request line");
    return;
  }

  std::string line;
  while (readLine(client, line)) {
    if (line.empty())
      break;
    size_t colon = line.find(':');
    if (colon == std::string::npos)
      continue;
    std::string name = lower(trim(line.substr(0, colon)));
    std::string value = trim(line.substr(colon + 1));
    if (name == "content-length")
      request.contentLength = strtoull(value.c_str(), nullptr, 10);
    if (name == "x-bikecomputer-transfer-token")
      request.transferToken = value;
  }

  HttpRequestHandler *handler = handlerForPath(request.path);
  if (handler != nullptr && handler->handleRequest(request, client))
    return;

  sendError(client, 404, "not_found", "device transfer endpoint not found");
}

HttpRequestHandler *
HttpTransferServer::handlerForPath(const std::string &path) const {
  HttpRequestHandler *best = nullptr;
  size_t bestLength = 0;
  for (size_t i = 0; i < handlerCount_; ++i) {
    const HandlerRegistration &registration = handlers_[i];
    if (registration.handler == nullptr)
      continue;
    const std::string &prefix = registration.pathPrefix;
    if (path.compare(0, prefix.size(), prefix) == 0 &&
        prefix.size() >= bestLength) {
      best = registration.handler;
      bestLength = prefix.size();
    }
  }
  return best;
}

std::string HttpTransferServer::generateSessionToken() const {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string token;
  token.reserve(32);
  for (int i = 0; i < 4; ++i) {
    uint32_t value = esp_random();
    for (int shift = 28; shift >= 0; shift -= 4) {
      token.push_back(kHex[(value >> shift) & 0x0F]);
    }
  }
  return token;
}

void HttpTransferServer::sendError(WiFiClient &client, int status,
                                   const std::string &code,
                                   const std::string &message) {
  setLastError(code, message);
  sendHttpError(client, status, code, message);
}

void HttpTransferServer::rememberError(const std::string &code,
                                       const std::string &message) {
  lastErrorCode_ = code;
  lastErrorMessage_ = message;
}

void HttpTransferServer::lockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreTake(stateMutex_, portMAX_DELAY);
}

void HttpTransferServer::unlockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreGive(stateMutex_);
}

void sendHttpHead(WiFiClient &client, int status, uint64_t contentLength) {
  const char *reason = status == 200   ? "OK"
                       : status == 400 ? "Bad Request"
                       : status == 403 ? "Forbidden"
                       : status == 404 ? "Not Found"
                                       : "Internal Server Error";
  client.printf("HTTP/1.1 %d %s\r\n", status, reason);
  client.print("Connection: close\r\n");
  client.printf("Content-Length: %llu\r\n\r\n",
                static_cast<unsigned long long>(contentLength));
}

void sendHttpJson(WiFiClient &client, int status, const std::string &body) {
  const char *reason = status == 200   ? "OK"
                       : status == 202 ? "Accepted"
                       : status == 400 ? "Bad Request"
                       : status == 401 ? "Unauthorized"
                       : status == 403 ? "Forbidden"
                       : status == 404 ? "Not Found"
                       : status == 409 ? "Conflict"
                       : status == 408 ? "Request Timeout"
                       : status == 413 ? "Payload Too Large"
                                       : "Internal Server Error";
  client.printf("HTTP/1.1 %d %s\r\n", status, reason);
  client.print("Content-Type: application/json\r\n");
  client.print("Connection: close\r\n");
  client.printf("Content-Length: %u\r\n\r\n",
                static_cast<unsigned>(body.size()));
  client.print(body.c_str());
}

void sendHttpError(WiFiClient &client, int status, const std::string &code,
                   const std::string &message) {
  sendHttpJson(client, status,
               std::string("{\"ok\":false,\"error\":{\"code\":\"") +
                   jsonEscape(code) + "\",\"message\":\"" +
                   jsonEscape(message) + "\"}}");
}

bool readHttpBody(WiFiClient &client, uint64_t contentLength,
                  uint64_t maxLength, std::string &body,
                  uint32_t timeoutMs) {
  body.clear();
  if (contentLength > maxLength)
    return false;
  body.reserve(static_cast<size_t>(contentLength));
  uint8_t buffer[256];
  uint64_t remaining = contentLength;
  uint32_t lastReadMs = millis();
  while (remaining > 0 && millis() - lastReadMs < timeoutMs) {
    int available = client.available();
    if (available <= 0) {
      delay(1);
      continue;
    }
    size_t toRead = std::min<uint64_t>(sizeof(buffer), remaining);
    toRead = std::min<size_t>(toRead, static_cast<size_t>(available));
    int read = client.read(buffer, toRead);
    if (read <= 0) {
      delay(1);
      continue;
    }
    body.append(reinterpret_cast<const char *>(buffer),
                static_cast<size_t>(read));
    remaining -= static_cast<uint64_t>(read);
    lastReadMs = millis();
  }
  return remaining == 0;
}

} // namespace device_transfer
