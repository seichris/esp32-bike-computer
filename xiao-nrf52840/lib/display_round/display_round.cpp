#include "display_round.hpp"

#include "round_display_pins.hpp"

namespace xiao_round {

bool DisplayRound::begin() {
  pinMode(pins::backlight, OUTPUT);
  pinMode(pins::touchInt, INPUT);
  pinMode(pins::lcdCs, OUTPUT);
  pinMode(pins::sdCs, OUTPUT);
  pinMode(pins::lcdDc, OUTPUT);

  digitalWrite(pins::lcdCs, HIGH);
  digitalWrite(pins::sdCs, HIGH);
  setBrightness(brightnessPercent);

  Serial.println("DisplayRound: pin-level init complete");
  Serial.println("DisplayRound: vendor display driver not initialized in skeleton");
  return true;
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
  Serial.println("DisplayRound: boot screen placeholder");
}

void DisplayRound::drawStatus(const char *line1, const char *line2) {
  Serial.print("DisplayRound: status: ");
  Serial.print(line1 == nullptr ? "" : line1);
  Serial.print(" | ");
  Serial.println(line2 == nullptr ? "" : line2);
}

void DisplayRound::beginMapFrame() {
  frameActive = true;
  frameLineCount = 0;
}

void DisplayRound::drawLine(int16_t, int16_t, int16_t, int16_t,
                            uint16_t) {
  if (frameActive) {
    frameLineCount++;
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
}

} // namespace xiao_round
