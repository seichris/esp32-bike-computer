#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace map_block_format {

constexpr size_t kMaximumBlockBytes = 2U * 1024U * 1024U;
constexpr uint32_t kMaximumFeatures = 16384;
constexpr uint32_t kMaximumPoints = 262144;
// The renderer expands every polygon bbox into a 16x16 spatial grid. Bound
// that decoded index separately from encoded feature/point counts so a small
// block cannot amplify into all available PSRAM.
constexpr uint32_t kMaximumPolygonGridEntries = 262144;

// Performs the same structural walk as the renderer without allocating or
// dereferencing beyond the supplied bytes. Only renderer-supported binary map
// versions are accepted and every byte must belong to a complete record.
bool validate(const uint8_t *data, size_t size);

class StreamValidator {
public:
  explicit StreamValidator(const std::string &path);
  bool feed(const uint8_t *data, size_t size);
  bool finish();
  bool failed() const { return failed_; }

private:
  enum class Format { Invalid, Binary, Ascii };
  enum class BinaryState {
    Header,
    PolygonCount,
    PolygonFixed,
    PolygonPointCount,
    PolygonPoints,
    PolylineCount,
    PolylineFixed,
    PolylinePointCount,
    PolylinePoints,
    Complete,
  };
  enum class AsciiState {
    PolygonHeader,
    PolygonColor,
    PolygonZoom,
    PolygonTypeOrBbox,
    PolygonBbox,
    PolygonCoords,
    PolylineHeader,
    PolylineColor,
    PolylineWidth,
    PolylineZoom,
    PolylineTypeOrBbox,
    PolylineBbox,
    PolylineCoords,
    Complete,
  };
  enum class CoordinateState { Prefix, XStart, XDigits, YStart, YDigits };

  Format format_ = Format::Invalid;
  bool failed_ = false;
  BinaryState binaryState_ = BinaryState::Header;
  uint8_t binaryVersion_ = 0;
  uint8_t small_[4] = {};
  size_t smallSize_ = 0;
  uint8_t binaryFixed_[13] = {};
  size_t binaryFixedSize_ = 0;
  size_t binaryRemaining_ = 0;
  uint32_t recordsRemaining_ = 0;
  size_t bytesSeen_ = 0;
  uint32_t featuresSeen_ = 0;
  uint32_t pointsSeen_ = 0;
  uint32_t polygonGridEntries_ = 0;
  AsciiState asciiState_ = AsciiState::PolygonHeader;
  std::string line_;
  CoordinateState coordinateState_ = CoordinateState::Prefix;
  size_t coordinatePrefix_ = 0;
  int32_t coordinateValue_ = 0;
  int coordinateSign_ = 1;
  bool coordinateHasDigit_ = false;
  bool coordinateLineHasPair_ = false;

  bool feedBinary(uint8_t byte);
  bool feedAscii(uint8_t byte);
  bool finishAsciiLine();
  bool feedCoordinate(uint8_t byte);
  void beginBinaryFixed(BinaryState state, size_t bytes);
  void beginCoordinateLine();
  bool addPolygonGridEntries(int16_t minX, int16_t minY, int16_t maxX,
                             int16_t maxY);
};

} // namespace map_block_format
