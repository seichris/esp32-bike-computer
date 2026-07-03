/**
 * @file rideTelemetryScr.hpp
 * @brief LVGL ride telemetry screen
 */

#pragma once

#include "globalGuiDef.h"

extern lv_obj_t *rideSpeedValue;
extern lv_obj_t *rideAltitudeValue;
extern lv_obj_t *rideDistanceValue;
extern lv_obj_t *rideElapsedValue;
extern lv_obj_t *rideRouteRemainingValue;

void rideTelemetryScr(_lv_obj_t *screen);
void updateRideTelemetryEvent(lv_event_t *event);
