#include "map_lite_core.hpp"

#include <cmath>
#include <cstdio>

namespace xiao_round {
namespace map_lite_core {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kDegToRad = 0.017453292519943295769;
constexpr double EARTH_RADIUS_METERS = 6378137.0;
constexpr int32_t MAX_MERCATOR_LAT_MICRODEGREES = 85051128;
constexpr int32_t MAX_LON_MICRODEGREES = 180000000;

int32_t roundToInt32(double value) {
  return static_cast<int32_t>(value >= 0.0 ? value + 0.5 : value - 0.5);
}

} // namespace

int32_t floorDiv(int32_t value, int32_t divisor) {
  int32_t quotient = value / divisor;
  const int32_t remainder = value % divisor;
  if (remainder != 0 && ((remainder < 0) != (divisor < 0))) {
    quotient--;
  }
  return quotient;
}

int32_t blockCoordForMapMeters(int32_t mapMeters) {
  return floorDiv(mapMeters, MAPBLOCK_SIZE_METERS);
}

bool gpsToMapMeters(int32_t latMicrodegrees, int32_t lonMicrodegrees,
                    int32_t &mapMetersX, int32_t &mapMetersY) {
  if ((latMicrodegrees == 0 && lonMicrodegrees == 0) ||
      latMicrodegrees < -MAX_MERCATOR_LAT_MICRODEGREES ||
      latMicrodegrees > MAX_MERCATOR_LAT_MICRODEGREES ||
      lonMicrodegrees < -MAX_LON_MICRODEGREES ||
      lonMicrodegrees > MAX_LON_MICRODEGREES) {
    return false;
  }

  const double latDegrees =
      static_cast<double>(latMicrodegrees) / 1000000.0;
  const double lonDegrees =
      static_cast<double>(lonMicrodegrees) / 1000000.0;
  const double latRadians = latDegrees * kDegToRad;
  mapMetersX = roundToInt32(lonDegrees * kDegToRad * EARTH_RADIUS_METERS);
  mapMetersY = roundToInt32(
      std::log(std::tan((latRadians * 0.5) + (kPi * 0.25))) *
      EARTH_RADIUS_METERS);
  return true;
}

void formatBlockPath(char *out, size_t outSize, const char *prefix,
                     int32_t mapMetersX, int32_t mapMetersY) {
  if (out == nullptr || outSize == 0) {
    return;
  }
  if (prefix == nullptr) {
    prefix = "";
  }

  const int32_t blockCoordX = blockCoordForMapMeters(mapMetersX);
  const int32_t blockCoordY = blockCoordForMapMeters(mapMetersY);
  const int32_t blockX = blockCoordX & MAPFOLDER_BLOCK_MASK;
  const int32_t blockY = blockCoordY & MAPFOLDER_BLOCK_MASK;
  const int32_t folderX = blockCoordX >> MAPFOLDER_BLOCK_BITS;
  const int32_t folderY = blockCoordY >> MAPFOLDER_BLOCK_BITS;

  char folderName[24];
  std::snprintf(folderName, sizeof(folderName), "%+04ld%+04ld",
                static_cast<long>(folderX), static_cast<long>(folderY));
  std::snprintf(out, outSize, "%s/%s/%ld_%ld.fmb", prefix, folderName,
                static_cast<long>(blockX), static_cast<long>(blockY));
}

int16_t localMapCoordToScreen(int16_t value, bool invert) {
  int32_t clamped = value;
  if (clamped < 0) {
    clamped = 0;
  } else if (clamped > MAPBLOCK_SIZE_METERS - 1) {
    clamped = MAPBLOCK_SIZE_METERS - 1;
  }
  int32_t screen =
      (clamped * (SCREEN_WIDTH - 1) + (MAPBLOCK_SIZE_METERS / 2)) /
      (MAPBLOCK_SIZE_METERS - 1);
  if (invert) {
    screen = (SCREEN_HEIGHT - 1) - screen;
  }
  return static_cast<int16_t>(screen);
}

bool isCandidatePolygon(uint8_t version, uint8_t typeId) {
  if (version < 2) {
    return false;
  }
  return typeId >= 150 && typeId < 200;
}

bool isCandidatePolyline(uint8_t version, uint8_t typeId) {
  if (version < 2) {
    return false;
  }
  return (typeId >= 1 && typeId < 100) || typeId == 152 || typeId == 153 ||
         typeId == 210;
}

Decision decide(const ProbeStats &stats) {
  if (!stats.headerValid || !stats.scanValid) {
    return Decision::Invalid;
  }
  if (stats.candidatePolygonCount == 0 &&
      stats.candidatePolylineCount == 0) {
    return Decision::NoData;
  }
  if (stats.scanMs > INTERACTION_BUDGET_MS) {
    return Decision::TooSlow;
  }
  const uint32_t candidateFeatures =
      stats.candidatePolygonCount + stats.candidatePolylineCount;
  if (candidateFeatures > CANDIDATE_FEATURE_BUDGET ||
      stats.candidatePointCount > CANDIDATE_POINT_BUDGET) {
    return Decision::TooComplex;
  }
  return Decision::Candidate;
}

const char *decisionName(Decision decision) {
  switch (decision) {
  case Decision::NoData:
    return "no-data";
  case Decision::Candidate:
    return "candidate";
  case Decision::TooSlow:
    return "too-slow";
  case Decision::TooComplex:
    return "too-complex";
  case Decision::Invalid:
    return "invalid";
  case Decision::Unknown:
  default:
    return "unknown";
  }
}

} // namespace map_lite_core
} // namespace xiao_round
