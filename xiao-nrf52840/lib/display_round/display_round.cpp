#include "display_round.hpp"

#include "round_display_pins.hpp"

#include <SPI.h>
#include <TFT_eSPI.h>

namespace xiao_round {
namespace {

constexpr uint16_t BACKGROUND_COLOR = TFT_BLACK;
constexpr uint16_t PRIMARY_TEXT_COLOR = TFT_WHITE;
constexpr uint16_t SECONDARY_TEXT_COLOR = TFT_CYAN;
constexpr uint16_t STATUS_PANEL_COLOR = 0x0008;
constexpr uint16_t ACCENT_COLOR = TFT_GREEN;

TFT_eSPI tft;

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

} // namespace xiao_round
