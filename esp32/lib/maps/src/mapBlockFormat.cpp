#include "mapBlockFormat.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>

namespace map_block_format {
namespace {

uint16_t littleEndian16(const uint8_t bytes[2]) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

bool unsignedValue(const std::string &text, uint32_t maximum,
                   uint32_t &value) {
  if (text.empty())
    return false;
  uint32_t parsed = 0;
  for (const char character : text) {
    if (character < '0' || character > '9')
      return false;
    const uint32_t digit = static_cast<uint32_t>(character - '0');
    if (parsed > (maximum - digit) / 10U)
      return false;
    parsed = parsed * 10U + digit;
  }
  value = parsed;
  return true;
}

bool smallUnsignedOrEmpty(const std::string &text) {
  if (text.empty())
    return true;
  uint32_t value = 0;
  return unsignedValue(text, 255, value);
}

bool colorValue(const std::string &text) {
  if (text.size() < 3 || text.size() > 10 || text[0] != '0' ||
      text[1] != 'x')
    return false;
  return std::all_of(text.begin() + 2, text.end(), [](unsigned char value) {
    return std::isxdigit(value) != 0;
  });
}

bool signed16(const std::string &text, size_t &offset, int16_t &result) {
  if (offset >= text.size())
    return false;
  int sign = 1;
  if (text[offset] == '-') {
    sign = -1;
    offset++;
  } else if (text[offset] == '+') {
    offset++;
  }
  if (offset >= text.size() || text[offset] < '0' || text[offset] > '9')
    return false;
  uint32_t value = 0;
  while (offset < text.size() && text[offset] >= '0' && text[offset] <= '9') {
    const uint32_t digit = static_cast<uint32_t>(text[offset] - '0');
    const uint32_t limit = sign > 0 ? 32767U : 32768U;
    if (value > (limit - digit) / 10U)
      return false;
    value = value * 10U + digit;
    offset++;
  }
  result = static_cast<int16_t>(sign > 0 ? static_cast<int32_t>(value)
                                         : -static_cast<int32_t>(value));
  return true;
}

bool bboxValue(const std::string &text, int16_t values[4] = nullptr) {
  if (text.compare(0, 5, "bbox:") != 0)
    return false;
  size_t offset = 5;
  for (size_t index = 0; index < 4; ++index) {
    int16_t value = 0;
    if (!signed16(text, offset, value))
      return false;
    if (values != nullptr)
      values[index] = value;
    if (index < 3) {
      if (offset >= text.size() || text[offset++] != ',')
        return false;
    }
  }
  return offset == text.size();
}

int16_t littleEndianSigned16(const uint8_t *bytes) {
  return static_cast<int16_t>(static_cast<uint16_t>(bytes[0]) |
                              (static_cast<uint16_t>(bytes[1]) << 8U));
}

bool countHeader(const std::string &text, const char *prefix,
                 uint32_t &count) {
  const size_t prefixSize = std::strlen(prefix);
  return text.compare(0, prefixSize, prefix) == 0 &&
         unsignedValue(text.substr(prefixSize), 32767, count);
}

} // namespace

StreamValidator::StreamValidator(const std::string &path) {
  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".fmb") == 0)
    format_ = Format::Binary;
  else if (path.size() >= 4 &&
           path.compare(path.size() - 4, 4, ".fmp") == 0)
    format_ = Format::Ascii;
  else
    failed_ = true;
}

bool StreamValidator::feed(const uint8_t *data, size_t size) {
  if (failed_ || (data == nullptr && size != 0))
    return false;
  if (size > kMaximumBlockBytes - bytesSeen_) {
    failed_ = true;
    return false;
  }
  bytesSeen_ += size;
  for (size_t index = 0; index < size; ++index) {
    const bool accepted = format_ == Format::Binary
                              ? feedBinary(data[index])
                              : format_ == Format::Ascii && feedAscii(data[index]);
    if (!accepted) {
      failed_ = true;
      return false;
    }
  }
  return true;
}

void StreamValidator::beginBinaryFixed(BinaryState state, size_t bytes) {
  binaryState_ = state;
  binaryRemaining_ = bytes;
  binaryFixedSize_ = 0;
}

bool StreamValidator::addPolygonGridEntries(int16_t minX, int16_t minY,
                                            int16_t maxX, int16_t maxY) {
  const auto cell = [](int16_t coordinate) {
    if (coordinate <= 0)
      return 0;
    return std::min(15, static_cast<int>(coordinate) / 256);
  };
  const int minCellX = cell(minX);
  const int minCellY = cell(minY);
  const int maxCellX = cell(maxX);
  const int maxCellY = cell(maxY);
  if (minCellX > maxCellX || minCellY > maxCellY)
    return true;
  const uint32_t entries =
      static_cast<uint32_t>(maxCellX - minCellX + 1) *
      static_cast<uint32_t>(maxCellY - minCellY + 1);
  if (entries > kMaximumPolygonGridEntries - polygonGridEntries_)
    return false;
  polygonGridEntries_ += entries;
  return true;
}

bool StreamValidator::feedBinary(uint8_t byte) {
  if (binaryState_ == BinaryState::Complete)
    return false;
  if (binaryState_ == BinaryState::Header) {
    small_[smallSize_++] = byte;
    if (smallSize_ != 4)
      return true;
    if (std::memcmp(small_, "FMB", 3) != 0 ||
        (small_[3] != 1 && small_[3] != 2))
      return false;
    binaryVersion_ = small_[3];
    smallSize_ = 0;
    binaryState_ = BinaryState::PolygonCount;
    return true;
  }
  if (binaryState_ == BinaryState::PolygonCount ||
      binaryState_ == BinaryState::PolygonPointCount ||
      binaryState_ == BinaryState::PolylineCount ||
      binaryState_ == BinaryState::PolylinePointCount) {
    small_[smallSize_++] = byte;
    if (smallSize_ != 2)
      return true;
    const uint16_t value = littleEndian16(small_);
    smallSize_ = 0;
    if (binaryState_ == BinaryState::PolygonCount) {
      recordsRemaining_ = value;
      featuresSeen_ = value;
      if (featuresSeen_ > kMaximumFeatures)
        return false;
      if (recordsRemaining_ == 0)
        binaryState_ = BinaryState::PolylineCount;
      else
        beginBinaryFixed(BinaryState::PolygonFixed,
                         11U + (binaryVersion_ == 2 ? 1U : 0U));
    } else if (binaryState_ == BinaryState::PolygonPointCount) {
      if (value == 0)
        return false;
      if (value > kMaximumPoints - pointsSeen_)
        return false;
      pointsSeen_ += value;
      beginBinaryFixed(BinaryState::PolygonPoints,
                       static_cast<size_t>(value) * 4U);
    } else if (binaryState_ == BinaryState::PolylineCount) {
      recordsRemaining_ = value;
      if (value > kMaximumFeatures - featuresSeen_)
        return false;
      featuresSeen_ += value;
      if (recordsRemaining_ == 0)
        binaryState_ = BinaryState::Complete;
      else
        beginBinaryFixed(BinaryState::PolylineFixed,
                         12U + (binaryVersion_ == 2 ? 1U : 0U));
    } else {
      if (value == 0)
        return false;
      if (value > kMaximumPoints - pointsSeen_)
        return false;
      pointsSeen_ += value;
      beginBinaryFixed(BinaryState::PolylinePoints,
                       static_cast<size_t>(value) * 4U);
    }
    return true;
  }

  if (binaryRemaining_ == 0)
    return false;
  if (binaryState_ == BinaryState::PolygonFixed) {
    if (binaryFixedSize_ >= sizeof(binaryFixed_))
      return false;
    binaryFixed_[binaryFixedSize_++] = byte;
  }
  binaryRemaining_--;
  if (binaryRemaining_ != 0)
    return true;
  if (binaryState_ == BinaryState::PolygonFixed) {
    const size_t bboxOffset = binaryVersion_ == 2 ? 4U : 3U;
    if (!addPolygonGridEntries(
            littleEndianSigned16(binaryFixed_ + bboxOffset),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 2U),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 4U),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 6U)))
      return false;
    binaryState_ = BinaryState::PolygonPointCount;
  } else if (binaryState_ == BinaryState::PolygonPoints) {
    if (--recordsRemaining_ == 0)
      binaryState_ = BinaryState::PolylineCount;
    else
      beginBinaryFixed(BinaryState::PolygonFixed,
                       11U + (binaryVersion_ == 2 ? 1U : 0U));
  } else if (binaryState_ == BinaryState::PolylineFixed) {
    binaryState_ = BinaryState::PolylinePointCount;
  } else if (binaryState_ == BinaryState::PolylinePoints) {
    if (--recordsRemaining_ == 0)
      binaryState_ = BinaryState::Complete;
    else
      beginBinaryFixed(BinaryState::PolylineFixed,
                       12U + (binaryVersion_ == 2 ? 1U : 0U));
  }
  return true;
}

void StreamValidator::beginCoordinateLine() {
  coordinateState_ = CoordinateState::Prefix;
  coordinatePrefix_ = 0;
  coordinateValue_ = 0;
  coordinateSign_ = 1;
  coordinateHasDigit_ = false;
  coordinateLineHasPair_ = false;
}

bool StreamValidator::feedCoordinate(uint8_t byte) {
  static constexpr char kPrefix[] = "coords:";
  if (coordinateState_ == CoordinateState::Prefix) {
    if (coordinatePrefix_ >= sizeof(kPrefix) - 1 ||
        byte != static_cast<uint8_t>(kPrefix[coordinatePrefix_++]))
      return false;
    if (coordinatePrefix_ == sizeof(kPrefix) - 1)
      coordinateState_ = CoordinateState::XStart;
    return true;
  }
  const auto startNumber = [&](CoordinateState digits) {
    coordinateValue_ = 0;
    coordinateSign_ = 1;
    coordinateHasDigit_ = false;
    if (byte == '-' || byte == '+') {
      coordinateSign_ = byte == '-' ? -1 : 1;
      coordinateState_ = digits;
      return true;
    }
    if (byte < '0' || byte > '9')
      return false;
    coordinateValue_ = byte - '0';
    coordinateHasDigit_ = true;
    coordinateState_ = digits;
    return true;
  };
  if (coordinateState_ == CoordinateState::XStart)
    return startNumber(CoordinateState::XDigits);
  if (coordinateState_ == CoordinateState::YStart)
    return startNumber(CoordinateState::YDigits);
  if (byte >= '0' && byte <= '9') {
    const int32_t digit = byte - '0';
    const int32_t limit = coordinateSign_ > 0 ? 32767 : 32768;
    if (coordinateValue_ > (limit - digit) / 10)
      return false;
    coordinateValue_ = coordinateValue_ * 10 + digit;
    coordinateHasDigit_ = true;
    return true;
  }
  if (coordinateState_ == CoordinateState::XDigits && coordinateHasDigit_ &&
      byte == ',') {
    coordinateState_ = CoordinateState::YStart;
    return true;
  }
  if (coordinateState_ == CoordinateState::YDigits && coordinateHasDigit_ &&
      byte == ';') {
    if (pointsSeen_ == kMaximumPoints)
      return false;
    pointsSeen_++;
    coordinateState_ = CoordinateState::XStart;
    coordinateLineHasPair_ = true;
    return true;
  }
  return false;
}

bool StreamValidator::finishAsciiLine() {
  uint32_t count = 0;
  switch (asciiState_) {
  case AsciiState::PolygonHeader:
    if (!countHeader(line_, "Polygons:", count))
      return false;
    recordsRemaining_ = count;
    featuresSeen_ = count;
    if (featuresSeen_ > kMaximumFeatures)
      return false;
    asciiState_ = recordsRemaining_ == 0 ? AsciiState::PolylineHeader
                                         : AsciiState::PolygonColor;
    break;
  case AsciiState::PolygonColor:
    if (!colorValue(line_))
      return false;
    asciiState_ = AsciiState::PolygonZoom;
    break;
  case AsciiState::PolygonZoom:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolygonTypeOrBbox;
    break;
  case AsciiState::PolygonTypeOrBbox:
    {
      int16_t bbox[4] = {};
      if (bboxValue(line_, bbox)) {
        if (!addPolygonGridEntries(bbox[0], bbox[1], bbox[2], bbox[3]))
          return false;
        asciiState_ = AsciiState::PolygonCoords;
        beginCoordinateLine();
      } else {
        uint32_t typeId = 0;
        if (!unsignedValue(line_, 255, typeId))
          return false;
        asciiState_ = AsciiState::PolygonBbox;
      }
    }
    break;
  case AsciiState::PolygonBbox:
    {
      int16_t bbox[4] = {};
      if (!bboxValue(line_, bbox) ||
          !addPolygonGridEntries(bbox[0], bbox[1], bbox[2], bbox[3]))
        return false;
      asciiState_ = AsciiState::PolygonCoords;
      beginCoordinateLine();
    }
    break;
  case AsciiState::PolylineHeader:
    if (!countHeader(line_, "Polylines:", count))
      return false;
    recordsRemaining_ = count;
    if (count > kMaximumFeatures - featuresSeen_)
      return false;
    featuresSeen_ += count;
    asciiState_ = recordsRemaining_ == 0 ? AsciiState::Complete
                                         : AsciiState::PolylineColor;
    break;
  case AsciiState::PolylineColor:
    if (!colorValue(line_))
      return false;
    asciiState_ = AsciiState::PolylineWidth;
    break;
  case AsciiState::PolylineWidth:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolylineZoom;
    break;
  case AsciiState::PolylineZoom:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolylineTypeOrBbox;
    break;
  case AsciiState::PolylineTypeOrBbox:
    if (bboxValue(line_)) {
      asciiState_ = AsciiState::PolylineCoords;
      beginCoordinateLine();
    } else {
      uint32_t typeId = 0;
      if (!unsignedValue(line_, 255, typeId))
        return false;
      asciiState_ = AsciiState::PolylineBbox;
    }
    break;
  case AsciiState::PolylineBbox:
    if (!bboxValue(line_))
      return false;
    asciiState_ = AsciiState::PolylineCoords;
    beginCoordinateLine();
    break;
  case AsciiState::PolygonCoords:
  case AsciiState::PolylineCoords:
  case AsciiState::Complete:
    return false;
  }
  line_.clear();
  return true;
}

bool StreamValidator::feedAscii(uint8_t byte) {
  if (byte == '\r')
    return true;
  if (asciiState_ == AsciiState::Complete)
    return false;
  const bool coordinates = asciiState_ == AsciiState::PolygonCoords ||
                           asciiState_ == AsciiState::PolylineCoords;
  if (byte != '\n') {
    if (coordinates)
      return feedCoordinate(byte);
    if (line_.size() >= 128)
      return false;
    line_.push_back(static_cast<char>(byte));
    return true;
  }
  if (!coordinates)
    return finishAsciiLine();
  if (coordinateState_ != CoordinateState::XStart ||
      !coordinateLineHasPair_)
    return false;
  if (asciiState_ == AsciiState::PolygonCoords) {
    if (--recordsRemaining_ == 0)
      asciiState_ = AsciiState::PolylineHeader;
    else
      asciiState_ = AsciiState::PolygonColor;
  } else {
    if (--recordsRemaining_ == 0)
      asciiState_ = AsciiState::Complete;
    else
      asciiState_ = AsciiState::PolylineColor;
  }
  return true;
}

bool StreamValidator::finish() {
  if (failed_)
    return false;
  return (format_ == Format::Binary &&
          binaryState_ == BinaryState::Complete) ||
         (format_ == Format::Ascii && asciiState_ == AsciiState::Complete);
}

bool validate(const uint8_t *data, size_t size) {
  StreamValidator validator("block.fmb");
  return validator.feed(data, size) && validator.finish();
}

} // namespace map_block_format
