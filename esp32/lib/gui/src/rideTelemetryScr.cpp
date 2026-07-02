/**
 * @file rideTelemetryScr.cpp
 * @brief LVGL ride telemetry screen
 */

#include "rideTelemetryScr.hpp"
#include "gps.hpp"
#include <cstdio>

extern Gps gps;

lv_obj_t *rideSpeedValue;
lv_obj_t *rideAltitudeValue;
lv_obj_t *rideDistanceValue;
lv_obj_t *rideElapsedValue;
lv_obj_t *rideRouteRemainingValue;

static lv_obj_t *createMetricLabel(lv_obj_t *screen, const char *title,
                                   lv_coord_t x, lv_coord_t y) {
  lv_obj_t *titleLabel = lv_label_create(screen);
  lv_obj_set_style_text_font(titleLabel, fontOptions, 0);
  lv_obj_set_style_text_color(titleLabel, lv_color_hex(0xAAAAAA), 0);
  lv_label_set_text_static(titleLabel, title);
  lv_obj_set_pos(titleLabel, x, y);

  lv_obj_t *valueLabel = lv_label_create(screen);
  lv_obj_set_style_text_font(valueLabel, fontLargeMedium, 0);
  lv_obj_set_style_text_color(valueLabel, lv_color_white(), 0);
  lv_label_set_text_static(valueLabel, "--");
  lv_obj_set_pos(valueLabel, x, y + 28);
  return valueLabel;
}

static void formatElapsed(uint32_t elapsedSeconds, char *buffer,
                          size_t bufferSize) {
  const uint32_t hours = elapsedSeconds / 3600;
  const uint32_t minutes = (elapsedSeconds / 60) % 60;
  const uint32_t seconds = elapsedSeconds % 60;

  if (hours > 0) {
    snprintf(buffer, bufferSize, "%lu:%02lu:%02lu", (unsigned long)hours,
             (unsigned long)minutes, (unsigned long)seconds);
  } else {
    snprintf(buffer, bufferSize, "%02lu:%02lu", (unsigned long)minutes,
             (unsigned long)seconds);
  }
}

static void setDistanceLabel(lv_obj_t *label, uint32_t meters) {
  if (meters >= 10000) {
    lv_label_set_text_fmt(label, "%lu km", (unsigned long)(meters / 1000));
  } else if (meters >= 1000) {
    lv_label_set_text_fmt(label, "%.1f km", meters / 1000.0f);
  } else {
    lv_label_set_text_fmt(label, "%lu m", (unsigned long)meters);
  }
}

void rideTelemetryScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  lv_obj_t *title = lv_label_create(screen);
  lv_obj_set_style_text_font(title, fontOptions, 0);
  lv_obj_set_style_text_color(title, lv_color_hex(0xAAAAAA), 0);
  lv_label_set_text_static(title, "Ride stats");
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 18);

  rideSpeedValue = lv_label_create(screen);
  lv_obj_set_style_text_font(rideSpeedValue, fontVeryLarge, 0);
  lv_obj_set_style_text_color(rideSpeedValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSpeedValue, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(rideSpeedValue, "0");
  lv_obj_set_width(rideSpeedValue, TFT_WIDTH);
  lv_obj_align(rideSpeedValue, LV_ALIGN_TOP_MID, 0, 52);

  lv_obj_t *speedUnit = lv_label_create(screen);
  lv_obj_set_style_text_font(speedUnit, fontOptions, 0);
  lv_obj_set_style_text_color(speedUnit, lv_color_hex(0xAAAAAA), 0);
  lv_label_set_text_static(speedUnit, "km/h");
  lv_obj_align(speedUnit, LV_ALIGN_TOP_MID, 0, 118);

  const lv_coord_t leftX = 34;
  const lv_coord_t rightX = TFT_WIDTH / 2 + 14;
  rideAltitudeValue = createMetricLabel(screen, "Altitude", leftX, 170);
  rideDistanceValue = createMetricLabel(screen, "Distance", rightX, 170);
  rideElapsedValue = createMetricLabel(screen, "Elapsed", leftX, 270);
  rideRouteRemainingValue =
      createMetricLabel(screen, "Route left", rightX, 270);
}

void updateRideTelemetryEvent(lv_event_t *event) {
  if (rideSpeedValue) {
    lv_label_set_text_fmt(rideSpeedValue, "%u", gps.gpsData.speed);
  }

  if (rideAltitudeValue) {
    lv_label_set_text_fmt(rideAltitudeValue, "%d m", gps.gpsData.altitude);
  }

  if (rideDistanceValue) {
    setDistanceLabel(rideDistanceValue, gps.gpsData.distanceTraveled);
  }

  if (rideElapsedValue) {
    char elapsed[16];
    formatElapsed(gps.gpsData.elapsedSeconds, elapsed, sizeof(elapsed));
    lv_label_set_text(rideElapsedValue, elapsed);
  }

  if (rideRouteRemainingValue) {
    if (gps.gpsData.hasRouteRemaining) {
      setDistanceLabel(rideRouteRemainingValue, gps.gpsData.routeRemaining);
    } else {
      lv_label_set_text_static(rideRouteRemainingValue, "--");
    }
  }
}
