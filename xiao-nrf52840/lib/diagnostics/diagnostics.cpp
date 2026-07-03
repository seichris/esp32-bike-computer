#include "diagnostics.hpp"

#include "rtc_pcf8563.hpp"

#include <sys/types.h>

extern "C" {
extern unsigned char __HeapLimit[];
caddr_t _sbrk(int incr);
}

extern uint32_t bootloaderVersion;

namespace xiao_round {
namespace {

constexpr uint32_t RUNTIME_LOG_INTERVAL_MS = 15000;

bool gpsFresh(const BLEDebugStats &stats, uint32_t now) {
  return stats.lastGpsPacketMs != 0 && now - stats.lastGpsPacketMs <= 10000;
}

void printResetFlag(uint32_t resetReason, uint32_t mask, const char *label,
                    bool &first) {
  if ((resetReason & mask) == 0) {
    return;
  }
  if (!first) {
    Serial.print(",");
  }
  Serial.print(label);
  first = false;
}

} // namespace

void Diagnostics::begin() {
  lastLogMs = millis();
  resetReason = readResetReason();
  bootloaderVersionValue = bootloaderVersion;
  logResetReason();
  Serial.print("Diagnostics: boot free_heap_approx=");
  Serial.println(approximateFreeHeapBytes());
}

void Diagnostics::update(const BLENavigationServer &bleServer,
                         const PowerManager &powerManager,
                         const RoundUi &roundUi,
                         const IdleSleepManager &idleSleepManager,
                         const MapLite &mapLite) {
  const uint32_t now = millis();
  if (now - lastLogMs < RUNTIME_LOG_INTERVAL_MS) {
    return;
  }
  lastLogMs = now;
  logSnapshot("runtime", bleServer, powerManager, roundUi, idleSleepManager,
              mapLite);
}

size_t Diagnostics::approximateFreeHeapBytes() const {
  const caddr_t currentBreak = _sbrk(0);
  if (currentBreak == reinterpret_cast<caddr_t>(-1) ||
      currentBreak >= reinterpret_cast<caddr_t>(__HeapLimit)) {
    return 0;
  }
  return static_cast<size_t>(reinterpret_cast<caddr_t>(__HeapLimit) -
                             currentBreak);
}

void Diagnostics::logSnapshot(const char *label,
                              const BLENavigationServer &bleServer,
                              const PowerManager &powerManager,
                              const RoundUi &roundUi,
                              const IdleSleepManager &idleSleepManager,
                              const MapLite &mapLite) {
  const BLEDebugStats stats = bleServer.getDebugStats();
  const bike_ble::RouteSummary &route = bleServer.currentRoute();
  const bike_ble::GpsPosition &gps = bleServer.currentGps();
  const BatteryStatus &battery = powerManager.battery();
  const IdleSleepStats &idleStats = idleSleepManager.stats();
  const MapLiteStatus mapStatus = mapLite.status();
  const uint32_t now = millis();

  Serial.print("Diagnostics: ");
  Serial.print(label == nullptr ? "snapshot" : label);
  Serial.print(" free_heap_approx=");
  Serial.print(approximateFreeHeapBytes());
  Serial.print(" reset_reason=0x");
  Serial.print(resetReason, HEX);
  Serial.print(" conn=");
  Serial.print(stats.connected);
  Serial.print(" auth=");
  Serial.print(stats.authenticated);
  Serial.print(" gps_fresh=");
  Serial.print(gpsFresh(stats, now));
  Serial.print(" route_pts=");
  Serial.print(route.pointCount);
  Serial.print(" route_bytes=");
  Serial.print(route.lengthBytes);
  Serial.print(" route_stored_pts=");
  Serial.print(route.storedPointCount);
  Serial.print(" route_truncated=");
  Serial.print(route.truncated);
  Serial.print(" gps_packets=");
  Serial.print(stats.gpsPacketCount);
  Serial.print(" nav_packets=");
  Serial.print(stats.navPacketCount);
  Serial.print(" route_packets=");
  Serial.print(stats.routePacketCount);
  Serial.print(" settings_packets=");
  Serial.print(stats.settingsPacketCount);
  Serial.print(" device_commands=");
  Serial.print(stats.deviceCommandCount);
  const rtc::Status &rtcStatus = rtc::status();
  Serial.print(" rtc_present=");
  Serial.print(rtcStatus.present);
  Serial.print(" rtc_valid=");
  Serial.print(rtcStatus.timeValid);
  Serial.print(" rtc_source=");
  Serial.print(rtc::sourceName(rtcStatus.source));
  Serial.print(" battery_mv=");
  Serial.print(battery.batteryMillivolts);
  Serial.print(" battery_pct=");
  Serial.print(battery.percent);
  Serial.print(" brightness=");
  Serial.print(powerManager.currentBrightness());
  Serial.print(" render_ms=");
  Serial.print(roundUi.lastRenderDurationMs());
  Serial.print(" render_max_ms=");
  Serial.print(roundUi.maxRenderDurationMs());
  Serial.print(" idle_calls=");
  Serial.print(idleStats.idleCallCount);
  Serial.print(" idle_total_ms=");
  Serial.print(idleStats.totalIdleMs);
  Serial.print(" idle_last_ms=");
  Serial.print(idleStats.lastIdleMs);
  Serial.print(" idle_max_ms=");
  Serial.print(idleStats.maxIdleMs);
  Serial.print(" map_sd=");
  Serial.print(mapStatus.sdReady);
  Serial.print(" map_has_probe=");
  Serial.print(mapStatus.hasProbe);
  Serial.print(" map_probes=");
  Serial.print(mapStatus.probeCount);
  Serial.print(" map_last_ms=");
  Serial.print(mapStatus.lastProbeMs);
  Serial.print(" map_from_gps=");
  Serial.print(mapStatus.lastProbeFromGps);
  Serial.print(" map_found=");
  Serial.print(mapStatus.lastResult.found);
  Serial.print(" map_decision=");
  Serial.print(MapLite::decisionName(mapStatus.lastResult.decision));
  Serial.print(" map_block=");
  Serial.print(mapStatus.lastBlockX);
  Serial.print(",");
  Serial.print(mapStatus.lastBlockY);
  Serial.print(" map_path=");
  Serial.print(mapStatus.lastResult.path);
  Serial.print(" map_open_ms=");
  Serial.print(mapStatus.lastResult.openMs);
  Serial.print(" map_scan_ms=");
  Serial.print(mapStatus.lastResult.scanMs);
  Serial.print(" map_candidate_pts=");
  Serial.print(mapStatus.lastResult.candidatePointCount);
  Serial.print(" map_renders=");
  Serial.print(mapStatus.renderCount);
  Serial.print(" map_render_valid=");
  Serial.print(mapStatus.lastRenderValid);
  Serial.print(" map_render_ms=");
  Serial.print(mapStatus.lastRenderMs);
  Serial.print(" map_render_features=");
  Serial.print(mapStatus.lastRenderedFeatureCount);
  Serial.print(" map_render_segments=");
  Serial.print(mapStatus.lastRenderedSegmentCount);
  Serial.print(" map_render_skipped=");
  Serial.print(mapStatus.lastSkippedSegmentCount);
  Serial.print(" map_render_budget=");
  Serial.print(mapStatus.lastRenderBudgetExceeded);
  Serial.print(" heading=");
  Serial.println(gps.headingDegrees);
}

void Diagnostics::logResetReason() const {
  Serial.print("Diagnostics: reset_reason=0x");
  Serial.print(resetReason, HEX);
  Serial.print(" reset_flags=");
  if (resetReason == 0) {
    Serial.print("power-on/unknown");
  } else {
    bool first = true;
#ifdef POWER_RESETREAS_RESETPIN_Msk
    printResetFlag(resetReason, POWER_RESETREAS_RESETPIN_Msk, "reset-pin",
                   first);
#endif
#ifdef POWER_RESETREAS_DOG_Msk
    printResetFlag(resetReason, POWER_RESETREAS_DOG_Msk, "watchdog", first);
#endif
#ifdef POWER_RESETREAS_SREQ_Msk
    printResetFlag(resetReason, POWER_RESETREAS_SREQ_Msk, "software", first);
#endif
#ifdef POWER_RESETREAS_LOCKUP_Msk
    printResetFlag(resetReason, POWER_RESETREAS_LOCKUP_Msk, "lockup", first);
#endif
#ifdef POWER_RESETREAS_OFF_Msk
    printResetFlag(resetReason, POWER_RESETREAS_OFF_Msk, "system-off", first);
#endif
#ifdef POWER_RESETREAS_LPCOMP_Msk
    printResetFlag(resetReason, POWER_RESETREAS_LPCOMP_Msk, "lpcomp", first);
#endif
#ifdef POWER_RESETREAS_DIF_Msk
    printResetFlag(resetReason, POWER_RESETREAS_DIF_Msk, "debug-interface",
                   first);
#endif
#ifdef POWER_RESETREAS_NFC_Msk
    printResetFlag(resetReason, POWER_RESETREAS_NFC_Msk, "nfc", first);
#endif
#ifdef POWER_RESETREAS_VBUS_Msk
    printResetFlag(resetReason, POWER_RESETREAS_VBUS_Msk, "vbus", first);
#endif
    if (first) {
      Serial.print("unmapped");
    }
  }
  Serial.print(" bootloader_version=0x");
  Serial.println(bootloaderVersionValue, HEX);
}

} // namespace xiao_round
