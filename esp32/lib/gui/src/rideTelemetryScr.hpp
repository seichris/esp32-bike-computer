/**
 * @file rideTelemetryScr.hpp
 * @brief Watch workout and legacy GPS Ride Stats screen.
 */

#pragma once

#include "globalGuiDef.h"
#include "rideTelemetryLayout.hpp"

void rideTelemetryScr(_lv_obj_t *screen);
void updateRideTelemetryEvent(lv_event_t *event);
void toggleRideTelemetryPage();
uint8_t currentRideTelemetryPage();
ride_telemetry_layout::InteractionAction handleRideTelemetryInteraction(
    ride_telemetry_layout::InteractionEvent event);
