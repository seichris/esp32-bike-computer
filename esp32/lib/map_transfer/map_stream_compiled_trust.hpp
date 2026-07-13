#pragma once

#include "map_stream_trust.hpp"

namespace map_transfer {

// Loads public verification keys compiled into firmware. Private signing keys
// never belong on the device. The initial list is intentionally empty so v2
// remains unadvertised until rollout provisions a production key.
MapStreamTrustStore compiledMapStreamTrustStore();

} // namespace map_transfer
