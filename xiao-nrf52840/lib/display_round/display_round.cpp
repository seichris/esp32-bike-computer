#include "display_round.hpp"

#include "round_display_pins.hpp"

#include <SPI.h>
#include <TFT_eSPI.h>
#include <Wire.h>
#include <stdio.h>

namespace xiao_round {
namespace {

constexpr uint16_t BACKGROUND_COLOR = TFT_BLACK;
constexpr uint16_t PRIMARY_TEXT_COLOR = TFT_WHITE;
constexpr uint16_t SECONDARY_TEXT_COLOR = TFT_CYAN;
constexpr uint16_t STATUS_PANEL_COLOR = 0x0008;
constexpr uint16_t MUTED_COLOR = 0x39E7;
constexpr uint16_t ACCENT_COLOR = TFT_GREEN;
constexpr uint16_t WARNING_COLOR = TFT_YELLOW;

TFT_eSPI tft;

void drawWideLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                  uint16_t color) {
  tft.drawLine(x1, y1, x2, y2, color);
  tft.drawLine(x1 + 1, y1, x2 + 1, y2, color);
  tft.drawLine(x1 - 1, y1, x2 - 1, y2, color);
  tft.drawLine(x1, y1 + 1, x2, y2 + 1, color);
  tft.drawLine(x1, y1 - 1, x2, y2 - 1, color);
}

void drawCenteredText(const char *text, int16_t y, uint8_t size,
                      uint16_t color) {
  tft.setTextSize(size);
  tft.setTextColor(color, BACKGROUND_COLOR);
  tft.setTextDatum(TC_DATUM);
  tft.drawString(text == nullptr ? "" : text, DisplayRound::width / 2, y);
}

void drawStatusPanel(const char *line1, const char *line2, bool overlay) {
  if (overlay) {
    tft.fillRect(0, 0, DisplayRound::width, 38, STATUS_PANEL_COLOR);
    tft.fillRect(0, DisplayRound::height - 42, DisplayRound::width, 42,
                 STATUS_PANEL_COLOR);
  } else {
    tft.fillScreen(BACKGROUND_COLOR);
  }

  tft.setTextDatum(TC_DATUM);
  tft.setTextSize(2);
  tft.setTextColor(PRIMARY_TEXT_COLOR, overlay ? STATUS_PANEL_COLOR
                                               : BACKGROUND_COLOR);
  tft.drawString(line1 == nullptr ? "" : line1, DisplayRound::width / 2,
                 overlay ? 8 : 76);

  tft.setTextSize(1);
  tft.setTextColor(SECONDARY_TEXT_COLOR, overlay ? STATUS_PANEL_COLOR
                                                 : BACKGROUND_COLOR);
  tft.drawString(line2 == nullptr ? "" : line2, DisplayRound::width / 2,
                 overlay ? DisplayRound::height - 28 : 128);
}

void drawArrowHead(int16_t tipX, int16_t tipY, int16_t leftX, int16_t leftY,
                   int16_t rightX, int16_t rightY, uint16_t color) {
  drawWideLine(tipX, tipY, leftX, leftY, color);
  drawWideLine(tipX, tipY, rightX, rightY, color);
}

void drawManeuverIcon(ManeuverIcon icon) {
  constexpr int16_t cx = DisplayRound::width / 2;
  constexpr int16_t cy = 114;
  constexpr int16_t top = 76;
  constexpr int16_t bottom = 152;
  constexpr int16_t left = 78;
  constexpr int16_t right = 162;
  constexpr int16_t elbowY = 100;

  switch (icon) {
  case ManeuverIcon::Left:
    drawWideLine(cx, bottom, cx, elbowY, ACCENT_COLOR);
    drawWideLine(cx, elbowY, left, elbowY, ACCENT_COLOR);
    drawArrowHead(left, elbowY, left + 18, elbowY - 14, left + 18,
                  elbowY + 14, ACCENT_COLOR);
    break;
  case ManeuverIcon::Right:
    drawWideLine(cx, bottom, cx, elbowY, ACCENT_COLOR);
    drawWideLine(cx, elbowY, right, elbowY, ACCENT_COLOR);
    drawArrowHead(right, elbowY, right - 18, elbowY - 14, right - 18,
                  elbowY + 14, ACCENT_COLOR);
    break;
  case ManeuverIcon::UTurn:
    drawWideLine(cx + 24, bottom, cx + 24, cy - 20, WARNING_COLOR);
    tft.drawCircle(cx, cy - 20, 24, WARNING_COLOR);
    tft.drawCircle(cx, cy - 20, 25, WARNING_COLOR);
    tft.drawCircle(cx, cy - 20, 26, WARNING_COLOR);
    drawWideLine(cx - 24, cy - 20, cx - 24, top + 10, WARNING_COLOR);
    drawArrowHead(cx - 24, top + 10, cx - 38, top + 28, cx - 10, top + 28,
                  WARNING_COLOR);
    break;
  case ManeuverIcon::Straight:
  default:
    drawWideLine(cx, bottom, cx, top, ACCENT_COLOR);
    drawArrowHead(cx, top, cx - 16, top + 22, cx + 16, top + 22,
                  ACCENT_COLOR);
    break;
  }
}

void drawRouteProgressArc(int16_t progressPermille) {
  if (progressPermille < 0) {
    return;
  }
  if (progressPermille > 1000) {
    progressPermille = 1000;
  }
  constexpr uint32_t startAngle = 210;
  constexpr uint32_t endAngle = 330;
  constexpr uint32_t span = endAngle - startAngle;
  const uint32_t progressEnd =
      startAngle + ((span * static_cast<uint32_t>(progressPermille)) / 1000U);
  tft.drawArc(DisplayRound::width / 2, DisplayRound::height / 2, 112, 105,
              startAngle, endAngle, MUTED_COLOR, BACKGROUND_COLOR, false);
  if (progressEnd > startAngle) {
    tft.drawArc(DisplayRound::width / 2, DisplayRound::height / 2, 112, 105,
                startAngle, progressEnd, ACCENT_COLOR, BACKGROUND_COLOR,
                false);
  }
}

} // namespace

bool DisplayRound::begin() {
  pinMode(pins::backlight, OUTPUT);
  pinMode(pins::touchInt, INPUT);
  pinMode(pins::lcdCs, OUTPUT);
  pinMode(pins::sdCs, OUTPUT);
  pinMode(pins::lcdDc, OUTPUT);

  digitalWrite(pins::lcdCs, HIGH);
  digitalWrite(pins::sdCs, HIGH);
  setBrightness(brightnessPercent);

  SPI.setPins(pins::spiMiso, pins::spiSck, pins::spiMosi);
  SPI.begin();
  Wire.setPins(pins::i2cSda, pins::i2cScl);
  Wire.begin();
  Wire.setClock(100000);
  tft.init();
  tft.setRotation(3);
  tft.fillScreen(BACKGROUND_COLOR);
  initialized = true;

  Serial.println("DisplayRound: Seeed_GFX GC9A01 init complete");
  return initialized;
}

void DisplayRound::setBrightness(uint8_t percent) {
  brightnessPercent = percent > 100 ? 100 : percent;
  const uint8_t duty = static_cast<uint8_t>((brightnessPercent * 255U) / 100U);
  analogWrite(pins::backlight, duty);
  Serial.print("DisplayRound: brightness=");
  Serial.print(brightnessPercent);
  Serial.println("%");
}

void DisplayRound::drawBootScreen() {
  if (initialized) {
    tft.fillScreen(BACKGROUND_COLOR);
    tft.drawCircle(width / 2, height / 2, 112, ACCENT_COLOR);
    drawCenteredText("Bike", 78, 3, PRIMARY_TEXT_COLOR);
    drawCenteredText("Computer", 112, 2, SECONDARY_TEXT_COLOR);
    drawCenteredText("XIAO nRF52840", 154, 1, PRIMARY_TEXT_COLOR);
  }
  Serial.println("DisplayRound: boot screen drawn");
}

void DisplayRound::drawStatus(const char *line1, const char *line2) {
  if (initialized) {
    drawStatusPanel(line1, line2, statusOverlayPending);
    statusOverlayPending = false;
  }
  Serial.print("DisplayRound: status: ");
  Serial.print(line1 == nullptr ? "" : line1);
  Serial.print(" | ");
  Serial.println(line2 == nullptr ? "" : line2);
}

void DisplayRound::drawNavigation(ManeuverIcon icon, uint16_t distanceMeters,
                                  const char *instruction,
                                  int16_t routeProgressPermille) {
  char distanceText[24];
  if (distanceMeters >= 1000) {
    snprintf(distanceText, sizeof(distanceText), "%u.%u km",
             distanceMeters / 1000, (distanceMeters % 1000) / 100);
  } else {
    snprintf(distanceText, sizeof(distanceText), "%u m", distanceMeters);
  }

  if (initialized) {
    tft.fillScreen(BACKGROUND_COLOR);
    drawCenteredText(distanceText, 36, 2, PRIMARY_TEXT_COLOR);
    drawManeuverIcon(icon);
    drawCenteredText(instruction == nullptr ? "No instruction" : instruction,
                     182, 1, SECONDARY_TEXT_COLOR);
    drawRouteProgressArc(routeProgressPermille);
  }

  Serial.print("DisplayRound: navigation icon=");
  Serial.print(static_cast<uint8_t>(icon));
  Serial.print(" distance=");
  Serial.print(distanceText);
  Serial.print(" progress_permille=");
  Serial.print(routeProgressPermille);
  Serial.print(" instruction=");
  Serial.println(instruction == nullptr ? "" : instruction);
}

void DisplayRound::beginMapFrame() {
  frameActive = true;
  statusOverlayPending = false;
  frameLineCount = 0;
  if (initialized) {
    tft.fillScreen(BACKGROUND_COLOR);
  }
}

void DisplayRound::drawLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                            uint16_t color) {
  if (frameActive) {
    frameLineCount++;
    if (initialized) {
      tft.drawLine(x1, y1, x2, y2, color);
    }
  }
}

void DisplayRound::endMapFrame(const char *label, uint32_t elapsedMs) {
  Serial.print("DisplayRound: map frame ");
  Serial.print(label == nullptr ? "preview" : label);
  Serial.print(" lines=");
  Serial.print(frameLineCount);
  Serial.print(" elapsed_ms=");
  Serial.println(elapsedMs);
  frameActive = false;
  statusOverlayPending = true;
}

bool DisplayRound::readTouch(int16_t &x, int16_t &y) {
  if (!initialized) {
    return false;
  }

  int32_t touchX = 0;
  int32_t touchY = 0;
  if (!tft.getTouch(&touchX, &touchY)) {
    return false;
  }
  if (touchX < 0 || touchY < 0 || touchX >= width || touchY >= height) {
    return false;
  }
  x = static_cast<int16_t>(touchX);
  y = static_cast<int16_t>(touchY);
  return true;
}

} // namespace xiao_round
