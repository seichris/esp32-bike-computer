def get_type_id(type_str):
    """Map an extracted OSM feature type string to its compact map type ID."""
    if not type_str:
        return 0

    feature_type = type_str.lower()
    feature_group = feature_type.partition(".")[0]

    # A building subtype may reuse words such as "residential" or "service".
    # Preserve the top-level OSM feature group before matching road subtypes.
    if feature_group == "building":
        return 100

    # Roads (1-49)
    if "motorway" in feature_type:
        return 1
    if "trunk" in feature_type:
        return 2
    if "primary" in feature_type:
        return 3
    if "secondary" in feature_type:
        return 4
    if "tertiary" in feature_type:
        return 5
    if "unclassified" in feature_type:
        return 6
    if "residential" in feature_type:
        return 7
    if "service" in feature_type:
        return 10

    # Paths (50-99)
    if "track" in feature_type:
        return 50
    if "cycleway" in feature_type:
        return 51
    if "footway" in feature_type:
        return 52
    if "path" in feature_type:
        return 53
    if "steps" in feature_type:
        return 54

    # Nature/Landuse (150-199)
    if "forest" in feature_type or "wood" in feature_type:
        return 150
    if "grass" in feature_type or "meadow" in feature_type:
        return 151
    if "water" in feature_type:
        return 152
    if "coastline" in feature_type:
        return 153
    if "park" in feature_type:
        return 154

    # Infrastructure/Other (200-255)
    if "amenity" in feature_type:
        return 200
    if "leisure" in feature_type:
        return 201
    if "railway" in feature_type:
        return 210

    return 0
