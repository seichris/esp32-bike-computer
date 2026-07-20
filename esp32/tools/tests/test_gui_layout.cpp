#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"

#include <cassert>

int main() {
#if defined(WAVESHARE_AMOLED_206)
  // 2.06-inch viewport: 502px screen with 72px reserved UI space.
  assert(gui_layout::mapViewportHeight(502) == 430);
  assert(gui_layout::mapScreenAnchorX(410, 410) == 205);
  assert(gui_layout::mapScreenAnchorY(502, 430) == 251);
  assert(gui_layout::mapScreenAnchorY(502, 502) == 251);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(410, 502);
#else
  // 1.75-inch viewport: 466px screen with 100px reserved UI space.
  assert(gui_layout::mapViewportHeight(466) == 366);
  assert(gui_layout::mapScreenAnchorX(466, 466) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 366) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 466) == 233);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(466, 466);
#endif
  static_assert(ride_telemetry_layout::isValid(rideLayout));
  assert(rideLayout.liveMetrics.size() == 6);
  assert(rideLayout.summaryMetrics.size() == 4);
  assert(rideLayout.status.right() <= rideLayout.pageIndicator.x);
  assert(rideLayout.liveMetrics[0].right() <=
         rideLayout.liveMetrics[1].x);
  assert(rideLayout.liveMetrics[3].bottom() <=
         rideLayout.liveMetrics[4].y);
  assert(rideLayout.summaryMetrics[3].bottom() <= rideLayout.source.y);
  for (const auto &metric : rideLayout.liveMetrics) {
    assert(ride_telemetry_layout::fits(
        metric, rideLayout.screenWidth, rideLayout.screenHeight));
  }
  for (const auto &metric : rideLayout.summaryMetrics) {
    assert(ride_telemetry_layout::fits(
        metric, rideLayout.screenWidth, rideLayout.screenHeight));
  }

  ride_telemetry_layout::InteractionState interaction{};
  using Action = ride_telemetry_layout::InteractionAction;
  using Event = ride_telemetry_layout::InteractionEvent;
  using Page = ride_telemetry_layout::Page;
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::Pressed) ==
         Action::None);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::Clicked) ==
         Action::CycleScreen);
  assert(interaction.page == Page::Live);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::Pressed) ==
         Action::None);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::LongPressed) ==
         Action::TogglePage);
  assert(interaction.page == Page::Summary);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::Clicked) ==
         Action::None);
  assert(interaction.page == Page::Summary);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::Pressed) ==
         Action::None);
  assert(ride_telemetry_layout::handleInteraction(interaction,
                                                  Event::LongPressed) ==
         Action::TogglePage);
  assert(interaction.page == Page::Live);
  return 0;
}
