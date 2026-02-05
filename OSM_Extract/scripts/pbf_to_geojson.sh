#!/bin/bash

# OpenStreetMap uses the WGS84 spatial reference system
# Most tiled web maps (such as the standard OSM maps and Google Maps) use this Mercator projection.
# WGS84 (EPSG 4326) => Mercator (EPSG 3857)

# First download the big pbf file of your area and store it in /fbf Check: https://download.geofabrik.de/

# Uncomment to clip the big pbf file to a reduced area. Adjust the clip_xxx.geojson clipping area -> check: http://geojson.io
# /maps/osmium extract --strategy=smart -p ../conf/clip_area.geojson /pbf/spain-latest.osm.pbf -o /pbf/clipped.pbf


# Extract the lines and polygons from the clipped pbf file
if [ $# -eq 0 ]; then
    echo " No arguments provided."
    echo " Usage:"
    echo "      $0 <min_lon> <min_lat> <max_lon> <max_lat> <pbf input file> <output file name>"
    echo ""
    exit 1
fi

rm -f $6_lines.geojson
rm -f $6_polygons.geojson
ogr2ogr -t_srs EPSG:3857 -spat $1 $2 $3 $4 $6_lines.geojson $5 lines 
ogr2ogr -t_srs EPSG:3857 -spat $1 $2 $3 $4 $6_polygons.geojson $5 multipolygons




