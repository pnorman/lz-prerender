#!/usr/bin/env bash

set -euf -o pipefail

PLANET_FILE='data.osm.pbf'

PLANET_URL='https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf'
PLANET_MD5_URL="${PLANET_URL}.md5"

OSMCARTO_VERSION="v4.20.0"
OSMCARTO_LOCATION='https://github.com/gravitystorm/openstreetmap-carto.git'

export PGDATABASE='osmcarto_prerender'
FLAT_NODES='nodes.bin'
OSM2PGSQL_CACHE='48000'

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
  seed: Create the tiles with MapProxy
  optimize: Optimize PNGs in cache
  tarball: Create tarballs with tiles
  upload: rsync files to dev
  dump: creates a pg_dump file of the database
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
  osmium fileinfo -g 'header.option.osmosis_replication_timestamp' "${PLANET_FILE}" > timestamp
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
  git -C openstreetmap-carto rev-parse HEAD > commit
}

function get_external() {
  openstreetmap-carto/scripts/get-shapefiles.py > /dev/null
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

function seed() {
  rm -rf osm_tiles
  mapproxy/bin/mapproxy-seed -s seed.yaml -f mapproxy.yaml -c 10 > /dev/null 2> seed.log
  rm -rf osm_tiles/tile_locks
}

function optimize() {
  find osm_tiles/{0,1,2,3,4,5,6}/ -type f -name '*.png' -print0 | parallel -0 -m optipng -quiet -o4 -strip all
  find osm_tiles/{7,8}/ -type f -name '*.png' -print0 | parallel -0 -m optipng -quiet -o2 -strip all
  find osm_tiles/{9,10}/ -type f -name '*.png' -print0 | parallel -0 -m optipng -quiet -o1 -strip all
}

function tarball() {
  mkdir -p tarballs

  cp commit osm_tiles/commit
  cp timestamp osm_tiles/timestamp

  # Figure out date code from timestamp
  DATECODE="$(date -u -f osm_tiles/timestamp '+%y%m%d')"

  GZIP='--rsyncable --best' tar -C osm_tiles --create --gzip --file "tarballs/z6-$DATECODE.tar.gz" commit timestamp 0 1 2 3 4 5 6
  GZIP='--rsyncable --best' tar -C osm_tiles --create --gzip --file "tarballs/z8-$DATECODE.tar.gz" commit timestamp 0 1 2 3 4 5 6 7 8
  GZIP='--rsyncable --best' tar -C osm_tiles --create --gzip --file "tarballs/z10-$DATECODE.tar.gz" commit timestamp 0 1 2 3 4 5 6 7 8 9 10
}

function upload() {
  DATECODE="$(date -u -f timestamp '+%y%m%d')"
  # Hard-coded to upload to errol, using rrsync on the other end to specify the directory
  rsync "tarballs/z6-$DATECODE.tar.gz"  "tarballs/z8-$DATECODE.tar.gz" "tarballs/z10-$DATECODE.tar.gz" pnorman@errol.openstreetmap.org:./
  rsync "osmcartodb-$DATECODE.bin" pnorman@errol.openstreetmap.org:./
}

function dump() {
  DATECODE="$(date -u -f timestamp '+%y%m%d')"

  pg_dump -f "osmcartodb-$DATECODE.bin"  -F c -Z 9 \
    -x -w -t planet_osm_line -t planet_osm_point -t planet_osm_polygon -t planet_osm_roads
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

    seed)
    shift
    seed
    ;;

    tarball)
    shift
    tarball
    ;;

    optimize)
    shift
    optimize
    ;;

    upload)
    shift
    upload
    ;;

    dump)
    shift
    dump
    ;;

    cron)
    shift
    download_planet &
    get_style
    get_external
    wait

    import_database

    dump &
    install_mapproxy
    seed
    optimize
    wait

    upload

    *)
    show_help
    ;;
esac
