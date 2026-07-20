/**
 * @file rideTelemetryScr.cpp
 * @brief Two-page Watch workout and legacy GPS ride telemetry screen.
 */

#include "rideTelemetryScr.hpp"
#include "../../ble_navigation/workout_telemetry_runtime.hpp"
#include "gps.hpp"
#include "rideTelemetryLayout.hpp"
#include "rideTelemetryPresenter.hpp"

#include <cstdio>
#include <cstring>

extern Gps gps;
LV_FONT_DECLARE(ride_value_font_56);

namespace {

constexpr lv_coord_t kMetricValueOffsetY = 26;

lv_obj_t *livePage = nullptr;
lv_obj_t *summaryPage = nullptr;
lv_obj_t *liveStatus = nullptr;
lv_obj_t *summaryStatus = nullptr;
lv_obj_t *rideSpeedValue = nullptr;
lv_obj_t *rideHeartRateValue = nullptr;
lv_obj_t *rideZoneValue = nullptr;
lv_obj_t *rideDistanceValue = nullptr;
lv_obj_t *rideElapsedValue = nullptr;
lv_obj_t *ridePowerValue = nullptr;
lv_obj_t *rideCadenceValue = nullptr;
lv_obj_t *rideAverageHeartRateValue = nullptr;
lv_obj_t *rideEnergyValue = nullptr;
lv_obj_t *rideAltitudeValue = nullptr;
lv_obj_t *rideRouteRemainingValue = nullptr;
lv_obj_t *rideSourceValue = nullptr;
ride_telemetry_layout::Layout rideLayout{};
ride_telemetry_layout::InteractionState interactionState{};

void setLabelIfChanged(lv_obj_t *label, const char *text) {
  if (label == nullptr || text == nullptr) {
    return;
  }
  const char *current = lv_label_get_text(label);
  if (current == nullptr || std::strcmp(current, text) != 0) {
    lv_label_set_text(label, text);
  }
}

lv_obj_t *createPage(lv_obj_t *screen) {
  lv_obj_t *page = lv_obj_create(screen);
  lv_obj_remove_style_all(page);
  lv_obj_set_size(page, rideLayout.page.width, rideLayout.page.height);
  lv_obj_set_pos(page, rideLayout.page.x, rideLayout.page.y);
  lv_obj_clear_flag(
      page, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                       LV_OBJ_FLAG_CLICKABLE));
  return page;
}

lv_obj_t *createHeader(lv_obj_t *page, const char *pageLabel) {
  lv_obj_t *status = lv_label_create(page);
  lv_obj_set_width(status, rideLayout.status.width);
  lv_obj_set_pos(status, rideLayout.status.x, rideLayout.status.y);
  lv_obj_set_style_text_font(status, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(status, lv_color_hex(0x66DD88), 0);
  lv_label_set_text_static(status, "LEGACY RIDE");

  lv_obj_t *indicator = lv_label_create(page);
  lv_obj_set_width(indicator, rideLayout.pageIndicator.width);
  lv_obj_set_pos(indicator, rideLayout.pageIndicator.x,
                 rideLayout.pageIndicator.y);
  lv_obj_set_style_text_font(indicator, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(indicator, lv_color_hex(0x888888), 0);
  lv_obj_set_style_text_align(indicator, LV_TEXT_ALIGN_RIGHT, 0);
  lv_label_set_text_static(indicator, pageLabel);
  return status;
}

lv_obj_t *createMetric(lv_obj_t *page, const char *title,
                       const ride_telemetry_layout::Rect &rect) {
  lv_obj_t *titleLabel = lv_label_create(page);
  lv_obj_set_width(titleLabel, rect.width);
  lv_obj_set_pos(titleLabel, rect.x, rect.y);
  lv_obj_set_style_text_font(titleLabel, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(titleLabel, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(titleLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(titleLabel, title);

  lv_obj_t *valueLabel = lv_label_create(page);
  lv_obj_set_width(valueLabel, rect.width);
  lv_obj_set_pos(valueLabel, rect.x, rect.y + kMetricValueOffsetY);
  lv_obj_set_style_text_font(valueLabel, &lv_font_montserrat_38, 0);
  lv_obj_set_style_text_color(valueLabel, lv_color_white(), 0);
  lv_obj_set_style_text_align(valueLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(valueLabel, LV_LABEL_LONG_CLIP);
  lv_label_set_text_static(valueLabel, "--");
  return valueLabel;
}

ride_telemetry_presenter::ViewModel currentViewModel() {
  const workout_telemetry::Snapshot workout =
      workout_telemetry_runtime::snapshot(millis());
  const ride_telemetry_presenter::LegacyRideTelemetry legacy{
      gps.gpsData.speed,
      gps.gpsData.altitude,
      gps.gpsData.distanceTraveled,
      gps.gpsData.elapsedSeconds,
      gps.gpsData.hasRouteRemaining,
      gps.gpsData.routeRemaining,
  };
  return ride_telemetry_presenter::makeViewModel(workout, legacy);
}

void updateStatusLabel(lv_obj_t *label,
                       const ride_telemetry_presenter::ViewModel &model) {
  setLabelIfChanged(label, ride_telemetry_presenter::statusLabel(model));
  lv_color_t color = lv_color_hex(0x66DD88);
  if (model.stale || model.sessionState ==
                         workout_telemetry_protocol::SessionState::Failed) {
    color = lv_color_hex(0xFF6666);
  } else if (model.sessionState ==
                 workout_telemetry_protocol::SessionState::Paused ||
             model.sessionState ==
                 workout_telemetry_protocol::SessionState::Ending) {
    color = lv_color_hex(0xFFCC55);
  } else if (model.sessionState ==
             workout_telemetry_protocol::SessionState::Ended) {
    color = lv_color_hex(0x66CCFF);
  }
  lv_obj_set_style_text_color(label, color, 0);
}

void updatePageVisibility() {
  if (livePage == nullptr || summaryPage == nullptr) {
    return;
  }
  if (interactionState.page == ride_telemetry_layout::Page::Live) {
    lv_obj_clear_flag(livePage, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(summaryPage, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(livePage, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(summaryPage, LV_OBJ_FLAG_HIDDEN);
  }
}

} // namespace

void rideTelemetryScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  rideLayout = ride_telemetry_layout::makeLayout(TFT_WIDTH, TFT_HEIGHT);

  livePage = createPage(screen);
  liveStatus = createHeader(livePage, "1 / 2");

  rideSpeedValue = lv_label_create(livePage);
  lv_obj_set_width(rideSpeedValue, rideLayout.hero.width);
  lv_obj_set_pos(rideSpeedValue, rideLayout.hero.x, rideLayout.hero.y);
  lv_obj_set_style_text_font(rideSpeedValue, &ride_value_font_56, 0);
  lv_obj_set_style_text_color(rideSpeedValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSpeedValue, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(rideSpeedValue, "0.0");

  lv_obj_t *speedUnit = lv_label_create(livePage);
  lv_obj_set_width(speedUnit, rideLayout.heroUnit.width);
  lv_obj_set_pos(speedUnit, rideLayout.heroUnit.x, rideLayout.heroUnit.y);
  lv_obj_set_style_text_font(speedUnit, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(speedUnit, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(speedUnit, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(speedUnit, "km/h");

  rideHeartRateValue =
      createMetric(livePage, "Heart bpm", rideLayout.liveMetrics[0]);
  rideZoneValue =
      createMetric(livePage, "HR zone", rideLayout.liveMetrics[1]);
  rideDistanceValue =
      createMetric(livePage, "Distance", rideLayout.liveMetrics[2]);
  rideElapsedValue =
      createMetric(livePage, "Elapsed", rideLayout.liveMetrics[3]);
  ridePowerValue =
      createMetric(livePage, "Power W", rideLayout.liveMetrics[4]);
  rideCadenceValue =
      createMetric(livePage, "Cadence rpm", rideLayout.liveMetrics[5]);

  summaryPage = createPage(screen);
  summaryStatus = createHeader(summaryPage, "2 / 2");
  rideAverageHeartRateValue = createMetric(
      summaryPage, "Avg heart bpm", rideLayout.summaryMetrics[0]);
  rideEnergyValue = createMetric(summaryPage, "Energy kcal",
                                 rideLayout.summaryMetrics[1]);
  rideAltitudeValue = createMetric(summaryPage, "Altitude m",
                                   rideLayout.summaryMetrics[2]);
  rideRouteRemainingValue = createMetric(
      summaryPage, "Route left", rideLayout.summaryMetrics[3]);

  lv_obj_t *sourceTitle = lv_label_create(summaryPage);
  lv_obj_set_width(sourceTitle, rideLayout.source.width);
  lv_obj_set_pos(sourceTitle, rideLayout.source.x, rideLayout.source.y);
  lv_obj_set_style_text_font(sourceTitle, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(sourceTitle, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(sourceTitle, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(sourceTitle, "Source / freshness");

  rideSourceValue = lv_label_create(summaryPage);
  lv_obj_set_width(rideSourceValue, rideLayout.source.width);
  lv_obj_set_pos(rideSourceValue, rideLayout.source.x,
                 rideLayout.source.y + 30);
  lv_obj_set_style_text_font(rideSourceValue, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(rideSourceValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSourceValue, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(rideSourceValue, LV_LABEL_LONG_CLIP);
  lv_label_set_text_static(rideSourceValue, "PHONE GPS");

  interactionState = {};
  updatePageVisibility();
  updateRideTelemetryEvent(nullptr);
}

void updateRideTelemetryEvent(lv_event_t *) {
  const ride_telemetry_presenter::ViewModel model = currentViewModel();
  updateStatusLabel(liveStatus, model);
  updateStatusLabel(summaryStatus, model);

  char value[24];
  ride_telemetry_presenter::formatSpeed(model, value, sizeof(value));
  setLabelIfChanged(rideSpeedValue, value);
  ride_telemetry_presenter::formatInteger(model.currentHeartRateBpm, value,
                                          sizeof(value));
  setLabelIfChanged(rideHeartRateValue, value);
  ride_telemetry_presenter::formatZone(model, value, sizeof(value));
  setLabelIfChanged(rideZoneValue, value);
  ride_telemetry_presenter::formatDistance(model.distanceMeters, value,
                                           sizeof(value));
  setLabelIfChanged(rideDistanceValue, value);
  ride_telemetry_presenter::formatElapsed(model.elapsedSeconds, value,
                                          sizeof(value));
  setLabelIfChanged(rideElapsedValue, value);
  ride_telemetry_presenter::formatInteger(model.cyclingPowerWatts, value,
                                          sizeof(value));
  setLabelIfChanged(ridePowerValue, value);
  ride_telemetry_presenter::formatCadence(model, value, sizeof(value));
  setLabelIfChanged(rideCadenceValue, value);

  ride_telemetry_presenter::formatInteger(model.averageHeartRateBpm, value,
                                          sizeof(value));
  setLabelIfChanged(rideAverageHeartRateValue, value);
  ride_telemetry_presenter::formatEnergy(model, value, sizeof(value));
  setLabelIfChanged(rideEnergyValue, value);
  ride_telemetry_presenter::formatInteger(model.altitudeMeters, value,
                                          sizeof(value));
  setLabelIfChanged(rideAltitudeValue, value);
  ride_telemetry_presenter::formatDistance(model.routeRemainingMeters, value,
                                           sizeof(value));
  setLabelIfChanged(rideRouteRemainingValue, value);
  setLabelIfChanged(rideSourceValue,
                    ride_telemetry_presenter::sourceFreshnessLabel(model));
}

void toggleRideTelemetryPage() {
  interactionState.page =
      ride_telemetry_layout::toggled(interactionState.page);
  updatePageVisibility();
  updateRideTelemetryEvent(nullptr);
}

uint8_t currentRideTelemetryPage() {
  return ride_telemetry_layout::pageIndex(interactionState.page);
}

ride_telemetry_layout::InteractionAction handleRideTelemetryInteraction(
    ride_telemetry_layout::InteractionEvent event) {
  const ride_telemetry_layout::InteractionAction action =
      ride_telemetry_layout::handleInteraction(interactionState, event);
  if (action == ride_telemetry_layout::InteractionAction::TogglePage) {
    updatePageVisibility();
    updateRideTelemetryEvent(nullptr);
  }
  return action;
}
