/**
 * @file tasks.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Core Tasks functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#ifdef HAS_HARDWARE_GPS
#include "gps.hpp"
#endif
#ifdef BME280
#include "bme.hpp"
#endif
#include "battery.hpp"
#ifdef ENABLE_COMPASS
#include "compass.hpp"
#endif
#include "lvgl.h"
#ifndef DISABLE_CLI
#include "cli.hpp"
#endif
// #include "mainScr.hpp"
#include "globalGpxDef.h"
#include "lvglFuncs.hpp"

#define TASK_SLEEP_PERIOD_MS 5

#ifdef HAS_HARDWARE_GPS
void gpsTask(void *pvParameters);
void initGpsTask();
#endif

#ifndef DISABLE_CLI
void cliTask(void *param);
void initCLITask();
#endif
