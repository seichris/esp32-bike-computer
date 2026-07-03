#pragma once

#include <cstddef>
#include <cstdint>

namespace xiao_round {
namespace map_lite_core {

constexpr uint8_t FMB_HEADER_SIZE = 6;
constexpr int32_t MAPBLOCK_SIZE_METERS = 4096;
constexpr uint8_t MAPFOLDER_BLOCK_BITS = 4;
constexpr int32_t MAPFOLDER_BLOCK_MASK = 0x0F;
constexpr uint32_t INTERACTION_BUDGET_MS = 150;
constexpr uint16_t CANDIDATE_FEATURE_BUDGET = 192;
constexpr uint32_t CANDIDATE_POINT_BUDGET = 2048;
constexpr uint16_t RENDER_SEGMENT_BUDGET = 160;
constexpr uint16_t RENDER_FEATURE_BUDGET = 80;
constexpr int16_t SCREEN_WIDTH = 240;
constexpr int16_t SCREEN_HEIGHT = 240;
constexpr bool DEFAULT_EXPERIMENT_ENABLED = false;

enum class Decision : uint8_t {
  Unknown,
  NoData,
  Candidate,
  TooSlow,
  TooComplex,
  Invalid,
};

struct ProbeStats {
  bool headerValid = false;
  bool scanValid = false;
  uint32_t scanMs = 0;
  uint16_t candidatePolygonCount = 0;
  uint16_t candidatePolylineCount = 0;
  uint32_t candidatePointCount = 0;
};

int32_t floorDiv(int32_t value, int32_t divisor);
int32_t blockCoordForMapMeters(int32_t mapMeters);
bool gpsToMapMeters(int32_t latMicrodegrees, int32_t lonMicrodegrees,
                    int32_t &mapMetersX, int32_t &mapMetersY);
void formatBlockPath(char *out, size_t outSize, const char *prefix,
                     int32_t mapMetersX, int32_t mapMetersY);
int16_t localMapCoordToScreen(int16_t value, bool invert);
bool isCandidatePolygon(uint8_t version, uint8_t typeId);
bool isCandidatePolyline(uint8_t version, uint8_t typeId);
Decision decide(const ProbeStats &stats);
const char *decisionName(Decision decision);

} // namespace map_lite_core
} // namespace xiao_round
