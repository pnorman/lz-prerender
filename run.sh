#!/usr/bin/env bash

set -euf -o pipefail

PLANET_FILE='data.osm.pbf'

PLANET_URL='http://download.geofabrik.de/europe/liechtenstein-latest.osm.pbf'
PLANET_MD5_URL="${PLANET_URL}.md5"

OSMCARTO_VERSION="v4.18.0"
OSMCARTO_LOCATION='https://github.com/gravitystorm/openstreetmap-carto.git'

export PGDATABASE='osmcarto_prerender'
FLAT_NODES='nodes.bin'
OSM2PGSQL_CACHE='4000'

CURL='curl -s -L'
function show_help() {
  cat << EOF
Usage: ${0##*/} mode

Modes:
  download: Download a new planet
  style: Download and build the style
  external: Download external data
  database: Import into the database
  mapproxy: Install MapProxy
EOF
}

function download_planet() {
  # Clean up any remaining files
  rm -f -- "${PLANET_FILE}" "${PLANET_FILE}.md5" 'state.txt' 'configuration.txt'

  # Because the planet file name is set above, the provided md5 file needs altering
  MD5="$($CURL "${PLANET_MD5_URL}" | cut -f1 -d' ')"
  echo "${MD5}  ${PLANET_FILE}" > "${PLANET_FILE}.md5"

  # Download the planet
  $CURL -o "${PLANET_FILE}" "${PLANET_URL}" || { echo "Planet file failed to download"; exit 1; }

  md5sum --quiet --status --strict -c "${PLANET_FILE}.md5" || { echo "md5 check failed"; exit 1; }

  REPLICATION_BASE_URL="$(osmium fileinfo -g 'header.option.osmosis_replication_base_url' "${PLANET_FILE}")"
  echo "baseUrl=${REPLICATION_BASE_URL}" > 'configuration.txt'

  # sed to turn into / formatted, see https://unix.stackexchange.com/a/113798/149591
  REPLICATION_SEQUENCE_NUMBER="$( printf "%09d" "$(osmium fileinfo -g 'header.option.osmosis_replication_sequence_number' "${PLANET_FILE}")" | sed ':a;s@\B[0-9]\{3\}\>@/&@;ta' )"

  $CURL -o 'state.txt' "${REPLICATION_BASE_URL}/${REPLICATION_SEQUENCE_NUMBER}.state.txt"
}

# Preconditions: None
# Postconditions:
# - openstreetmap-carto repo exists
# - openstreetmap-carto/project.xml exists
function get_style() {
  rm -rf -- 'openstreetmap-carto'
  git -c advice.detachedHead=false clone --quiet --depth 1 \
    --branch "${OSMCARTO_VERSION}" -- "${OSMCARTO_LOCATION}" 'openstreetmap-carto'

  git -C 'openstreetmap-carto' apply << EOF
diff --git a/project.mml b/project.mml
index b8c3217..a41e550 100644
--- a/project.mml
+++ b/project.mml
@@ -30,7 +30,7 @@ _parts:
     srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs"
   osm2pgsql: &osm2pgsql
     type: "postgis"
-    dbname: "gis"
+    dbname: "${PGDATABASE}"
     key_field: ""
     geometry_field: "way"
     extent: "-20037508,-20037508,20037508,20037508"
EOF
  carto -a 3.0.12 'openstreetmap-carto/project.mml' > 'openstreetmap-carto/project.xml'
}

function get_external() {
  openstreetmap-carto/scripts/get-shapefiles.py
}

function import_database() {
  # PGDATABASE is set, so postgres commands don't need a database name supplied

  # Clean up any existing db and files
  dropdb --if-exists "${PGDATABASE}"
  rm -f -- "${FLAT_NODES}"

  createdb
  psql -Xqw -c 'CREATE EXTENSION postgis; CREATE EXTENSION hstore;'

  osm2pgsql -G --hstore --style 'openstreetmap-carto/openstreetmap-carto.style' \
    --tag-transform-script 'openstreetmap-carto/openstreetmap-carto.lua' \
    --slim --drop --flat-nodes "${FLAT_NODES}" --cache "${OSM2PGSQL_CACHE}" \
    -d "${PGDATABASE}" "${PLANET_FILE}"

  rm -f -- "${FLAT_NODES}"

  openstreetmap-carto/scripts/indexes.py --fillfactor 100 | psql -Xqw -f -
}

function install_mapproxy() {
  rm -rf mapproxy
  virtualenv --quiet --system-site-packages mapproxy
  mapproxy/bin/pip install "MapProxy>=1.11.0,<=1.11.99"
}

command="$1"

case "$command" in
    download)
    shift
    download_planet
    ;;

    style)
    shift
    get_style
    ;;

    external)
    shift
    get_external
    ;;

    database)
    shift
    import_database
    ;;

    mapproxy)
    shift
    install_mapproxy
    ;;

    *)
    show_help
    ;;
esac
