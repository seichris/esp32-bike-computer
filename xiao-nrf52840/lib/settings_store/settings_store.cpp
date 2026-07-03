#include "settings_store.hpp"

#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>

using namespace Adafruit_LittleFS_Namespace;

namespace xiao_round {
namespace {

constexpr const char *SETTINGS_FILE = "/bike_settings.txt";

} // namespace

bool SettingsStore::begin() {
  ready = InternalFS.begin();
  Serial.print("SettingsStore: ");
  Serial.println(ready ? "ready" : "unavailable");
  return ready;
}

DeviceSettings SettingsStore::load() const {
  DeviceSettings settings;
  if (!ready) {
    return settings;
  }

  File file(InternalFS);
  if (!file.open(SETTINGS_FILE, FILE_O_READ)) {
    return settings;
  }

  char buffer[256] = {};
  const int readLen = file.read(buffer, sizeof(buffer) - 1);
  file.close();
  if (readLen <= 0) {
    return settings;
  }
  buffer[readLen] = '\0';
  return settings_core::parseSettingsText(buffer);
}

bool SettingsStore::save(const DeviceSettings &settings) {
  if (!ready) {
    return false;
  }

  if (InternalFS.exists(SETTINGS_FILE)) {
    InternalFS.remove(SETTINGS_FILE);
  }

  File file(InternalFS);
  if (!file.open(SETTINGS_FILE, FILE_O_WRITE)) {
    Serial.println("SettingsStore: failed to open settings for write");
    return false;
  }

  char buffer[320];
  const size_t formatLen =
      settings_core::formatSettingsText(settings, buffer, sizeof(buffer));
  if (formatLen == 0) {
    file.close();
    Serial.println("SettingsStore: formatted settings too large");
    return false;
  }
  const size_t written = file.write(buffer, formatLen);
  file.close();
  return written == formatLen;
}

} // namespace xiao_round
