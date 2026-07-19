#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ride_telemetry_layout {

struct Rect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;

  constexpr int32_t right() const { return x + width; }
  constexpr int32_t bottom() const { return y + height; }
};

struct Layout {
  int32_t screenWidth = 0;
  int32_t screenHeight = 0;
  Rect page{};
  Rect status{};
  Rect pageIndicator{};
  Rect hero{};
  Rect heroUnit{};
  std::array<Rect, 6> liveMetrics{};
  std::array<Rect, 4> summaryMetrics{};
  Rect source{};
};

constexpr Layout makeLayout(int32_t width, int32_t height) {
  constexpr int32_t columnGap = 12;
  constexpr int32_t metricFirstY = 136;
  constexpr int32_t metricRowSpacing = 98;
  constexpr int32_t metricCellHeight = 70;
  const int32_t columnWidth = (width - 36 - columnGap) / 2;
  const int32_t leftX = 12;
  const int32_t rightX = leftX + columnWidth + columnGap;

  Layout layout{};
  layout.screenWidth = width;
  layout.screenHeight = height;
  layout.page = {0, 0, width, height};
  layout.status = {16, 8, width - 112, 24};
  layout.pageIndicator = {width - 80, 8, 64, 24};
  layout.hero = {0, 30, width, 60};
  layout.heroUnit = {0, 92, width, 24};
  layout.liveMetrics = {{
      {leftX, metricFirstY, columnWidth, metricCellHeight},
      {rightX, metricFirstY, columnWidth, metricCellHeight},
      {leftX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
      {rightX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
      {leftX, metricFirstY + 2 * metricRowSpacing, columnWidth,
       metricCellHeight},
      {rightX, metricFirstY + 2 * metricRowSpacing, columnWidth,
       metricCellHeight},
  }};
  layout.summaryMetrics = {{
      {leftX, metricFirstY, columnWidth, metricCellHeight},
      {rightX, metricFirstY, columnWidth, metricCellHeight},
      {leftX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
      {rightX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
  }};
  layout.source = {16, metricFirstY + 2 * metricRowSpacing + 8,
                   width - 32, 64};
  return layout;
}

constexpr bool fits(const Rect &rect, int32_t width, int32_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.right() <= width && rect.bottom() <= height;
}

constexpr bool isValid(const Layout &layout) {
  if (!fits(layout.page, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.status, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.pageIndicator, layout.screenWidth,
            layout.screenHeight) ||
      !fits(layout.hero, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.heroUnit, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.source, layout.screenWidth, layout.screenHeight) ||
      layout.status.right() > layout.pageIndicator.x) {
    return false;
  }
  for (const Rect &metric : layout.liveMetrics) {
    if (!fits(metric, layout.screenWidth, layout.screenHeight)) {
      return false;
    }
  }
  for (const Rect &metric : layout.summaryMetrics) {
    if (!fits(metric, layout.screenWidth, layout.screenHeight)) {
      return false;
    }
  }
  for (std::size_t row = 0; row < 3; ++row) {
    const Rect &left = layout.liveMetrics[row * 2];
    const Rect &right = layout.liveMetrics[row * 2 + 1];
    if (left.right() > right.x) {
      return false;
    }
  }
  return layout.liveMetrics[3].bottom() <=
             layout.liveMetrics[4].y &&
         layout.summaryMetrics[3].bottom() <= layout.source.y;
}

enum class Page : uint8_t { Live = 0, Summary = 1 };
enum class InteractionEvent : uint8_t {
  Pressed,
  LongPressed,
  Clicked,
  Other,
};
enum class InteractionAction : uint8_t {
  None,
  TogglePage,
  CycleScreen,
};

struct InteractionState {
  Page page = Page::Live;
  bool longPressTriggered = false;
};

constexpr Page toggled(Page page) {
  return page == Page::Live ? Page::Summary : Page::Live;
}

constexpr InteractionAction handleInteraction(
    InteractionState &state, InteractionEvent event) {
  switch (event) {
  case InteractionEvent::Pressed:
    state.longPressTriggered = false;
    return InteractionAction::None;
  case InteractionEvent::LongPressed:
    state.longPressTriggered = true;
    state.page = toggled(state.page);
    return InteractionAction::TogglePage;
  case InteractionEvent::Clicked:
    return state.longPressTriggered ? InteractionAction::None
                                    : InteractionAction::CycleScreen;
  case InteractionEvent::Other:
    return InteractionAction::None;
  }
  return InteractionAction::None;
}

constexpr uint8_t pageIndex(Page page) {
  return static_cast<uint8_t>(page);
}

} // namespace ride_telemetry_layout
