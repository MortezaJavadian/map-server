#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

# ==============================================================================
# OFFLINE Map Manager - Sharded World Architecture
#
# Architecture:
#   maps/sources/<shard>/*.osm.pbf  -> durable source extracts
#   maps/tiles/<shard>.mbtiles      -> generated regional tile shards
#   maps/styles/*/style.runtime.json -> generated offline multi-shard styles
#
# A shard is the top-level Geofabrik region (asia, europe, africa, ...).
# Adding/updating a country rebuilds only its shard, not every map in the world.
# Existing shard MBTiles are replaced atomically only after a successful build.
# ==============================================================================

# ==============================================================================
# Base Paths / Environment
# ==============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found: $ENV_FILE" >&2
    echo "Create it with: cp .env.example .env" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

REQUIRED_ENV_VARS=(
    MAP_DOMAIN
    TILESERVER_IMAGE
    TILEMAKER_IMAGE
    FONTS_BUNDLE_URL
    GEOFABRIK_INDEX_URL
    COASTLINE_URL
    NATURAL_EARTH_URBAN_URL
    NATURAL_EARTH_ICE_SHELF_URL
    NATURAL_EARTH_GLACIER_URL
)

for var_name in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var_name:-}" ]; then
        echo "ERROR: Missing '$var_name' in .env" >&2
        exit 1
    fi
done

TILEMAKER_EXTRA_ARGS="${TILEMAKER_EXTRA_ARGS:-}"

# ==============================================================================
# Project Paths
# ==============================================================================

MAPS_DIR="$SCRIPT_DIR/maps"
CONFIG_DIR="$SCRIPT_DIR/tilemaker-config"

SOURCES_DIR="$MAPS_DIR/sources"
TILES_DIR="$MAPS_DIR/tiles"
STORE_DIR="$MAPS_DIR/temp_store"
STYLES_DIR="$MAPS_DIR/styles"
SPRITES_DIR="$MAPS_DIR/sprites"
FONTS_DIR="$MAPS_DIR/fonts"
DOWNLOADS_DIR="$MAPS_DIR/.downloads"
STATE_DIR="$MAPS_DIR/.state"

TILESERVER_CONFIG="$MAPS_DIR/config.json"
TEMP_CONFIG="$MAPS_DIR/config_tmp.json"
GEOFABRIK_INDEX_FILE="$DOWNLOADS_DIR/geofabrik-index.json"
LOCK_FILE="$MAPS_DIR/.manager.lock"

RUNTIME_STYLE_FILE="style.runtime.json"

COASTLINE_DIR="$CONFIG_DIR/coastline"
LANDCOVER_DIR="$CONFIG_DIR/landcover"

mkdir -p \
    "$MAPS_DIR" \
    "$SOURCES_DIR" \
    "$TILES_DIR" \
    "$STORE_DIR" \
    "$STYLES_DIR" \
    "$SPRITES_DIR" \
    "$DOWNLOADS_DIR" \
    "$STATE_DIR"

# ==============================================================================
# Runtime State
# ==============================================================================

CONFIG_CHANGED=false
SERVER_RESTART_REQUIRED=false
CONVERSION_FAILED=false
DOWNLOAD_COMPLETED=false
DOWNLOADED_SHARD=""
TILEMAKER_MULTI_INPUT_CHECKED=false
STYLE_CHANGED=false

# ==============================================================================
# CLI Output
# ==============================================================================

if [ -t 1 ]; then
    COLOR_BLUE=$'\033[1;34m'
    COLOR_GREEN=$'\033[1;32m'
    COLOR_YELLOW=$'\033[1;33m'
    COLOR_RED=$'\033[1;31m'
    COLOR_CYAN=$'\033[1;36m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_BLUE=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_CYAN=""
    COLOR_RESET=""
fi

section() {
    printf '\n%s==============================================================================%s\n' "$COLOR_BLUE" "$COLOR_RESET" >&2
    printf '%s%s%s\n' "$COLOR_BLUE" "$1" "$COLOR_RESET" >&2
    printf '%s==============================================================================%s\n' "$COLOR_BLUE" "$COLOR_RESET" >&2
}

info() {
    printf '%s>>>%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*" >&2
}

success() {
    printf '%s✔%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*" >&2
}

warn() {
    printf '%sWARNING:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

error() {
    printf '%sERROR:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "Required command '$1' is not installed."
}

verify_tilemaker_multi_input_support() {
    if [ "$TILEMAKER_MULTI_INPUT_CHECKED" = true ]; then
        return 0
    fi

    require_command docker

    # Parse-only capability check. --help makes tilemaker exit before opening
    # the fake input files, but Boost.Program_options still validates whether
    # multiple --input occurrences are accepted.
    if ! docker run --rm \
        "$TILEMAKER_IMAGE" \
        --help \
        --input /tmp/tilemaker-input-a.osm.pbf \
        --input /tmp/tilemaker-input-b.osm.pbf \
        --output /tmp/tilemaker-output.mbtiles \
        >/dev/null 2>&1
    then
        die "The configured Tilemaker image does not support multiple --input files. Use Tilemaker 3.1.0 or newer, then retry."
    fi

    TILEMAKER_MULTI_INPUT_CHECKED=true
}

# ==============================================================================
# Lock
# ==============================================================================

acquire_lock() {
    require_command flock

    exec 9>"$LOCK_FILE"

    if ! flock -n 9; then
        die "Another map_manager.sh process is already running."
    fi
}

# ==============================================================================
# Helpers
# ==============================================================================

download_resumable() {
    local url="$1"
    local output="$2"
    local description="${3:-Downloading file}"

    require_command curl

    mkdir -p "$(dirname "$output")"

    info "$description"
    printf '    URL: %s\n\n' "$url" >&2

    curl \
        --fail \
        --location \
        --show-error \
        --progress-bar \
        --retry 5 \
        --retry-delay 3 \
        --retry-connrefused \
        --connect-timeout 20 \
        --speed-time 60 \
        --speed-limit 1024 \
        --continue-at - \
        --output "$output" \
        "$url"
}

safe_extract_zip() {
    local archive="$1"
    local destination="$2"

    require_command unzip

    rm -rf "$destination"
    mkdir -p "$destination"

    unzip -q -o "$archive" -d "$destination"
}

# ==============================================================================
# Fonts
# ==============================================================================

font_tree_ready() {
    local root="$1"
    local file

    local required_files=(
        "Noto Sans Regular/0-255.pbf"
        "Noto Sans Regular/1536-1791.pbf"
        "Noto Sans Regular/64256-64511.pbf"
        "Noto Sans Regular/65024-65279.pbf"
        "Noto Sans Bold/0-255.pbf"
        "Noto Sans Italic/0-255.pbf"
        "Open Sans Regular/0-255.pbf"
        "Metropolis Regular/0-255.pbf"
        "PT Sans Regular/0-255.pbf"
        "Roboto Regular/0-255.pbf"
    )

    for file in "${required_files[@]}"; do
        [ -s "$root/$file" ] || return 1
    done

    return 0
}

ensure_fonts() {
    section "Checking local font glyphs"

    if font_tree_ready "$FONTS_DIR"; then
        success "Local fonts are ready."
        return 0
    fi

    warn "Font collection is missing or incomplete."

    require_command curl
    require_command tar

    local archive="$DOWNLOADS_DIR/fonts-bundle.tar.gz.part"
    local extract_dir="$DOWNLOADS_DIR/fonts-extract.$$"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    if ! download_resumable \
        "$FONTS_BUNDLE_URL" \
        "$archive" \
        "Downloading local PBF font bundle"
    then
        if ! tar -tzf "$archive" >/dev/null 2>&1; then
            rm -f "$archive"
            die "Unable to download font bundle."
        fi

        warn "Download returned an error, but the existing archive is valid."
    fi

    info "Validating font archive..."

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        warn "Downloaded font archive is invalid. Retrying from zero..."
        rm -f "$archive"

        download_resumable \
            "$FONTS_BUNDLE_URL" \
            "$archive" \
            "Re-downloading local PBF font bundle" \
            || die "Unable to download valid font bundle."

        tar -tzf "$archive" >/dev/null 2>&1 \
            || die "Downloaded font archive is invalid."
    fi

    info "Extracting font glyphs..."

    tar \
        -xzf "$archive" \
        -C "$extract_dir" \
        --strip-components=1

    if ! font_tree_ready "$extract_dir"; then
        rm -rf "$extract_dir"
        die "Downloaded font bundle does not contain required glyphs."
    fi

    info "Installing local fonts..."

    mkdir -p "$FONTS_DIR"
    cp -a "$extract_dir"/. "$FONTS_DIR"/
    chmod -R a+rX "$FONTS_DIR"

    if ! font_tree_ready "$FONTS_DIR"; then
        rm -rf "$extract_dir"
        die "Font installation validation failed."
    fi

    rm -rf "$extract_dir"
    rm -f "$archive"

    SERVER_RESTART_REQUIRED=true

    success "Local PBF fonts installed successfully."
}

# ==============================================================================
# Tilemaker Auxiliary Data: Coastline + Natural Earth
# ==============================================================================

auxiliary_data_ready() {
    [ -s "$COASTLINE_DIR/water_polygons.shp" ] \
        && [ -s "$COASTLINE_DIR/water_polygons.dbf" ] \
        && [ -s "$COASTLINE_DIR/water_polygons.shx" ] \
        && [ -s "$LANDCOVER_DIR/ne_10m_urban_areas/ne_10m_urban_areas.shp" ] \
        && [ -s "$LANDCOVER_DIR/ne_10m_antarctic_ice_shelves_polys/ne_10m_antarctic_ice_shelves_polys.shp" ] \
        && [ -s "$LANDCOVER_DIR/ne_10m_glaciated_areas/ne_10m_glaciated_areas.shp" ]
}

install_coastline() {
    local archive="$DOWNLOADS_DIR/water-polygons-split-4326.zip.part"
    local extract_dir="$DOWNLOADS_DIR/coastline-extract.$$"
    local source_shp
    local source_dir

    download_resumable \
        "$COASTLINE_URL" \
        "$archive" \
        "Downloading coastline polygons"

    require_command unzip
    unzip -tq "$archive" >/dev/null \
        || die "Downloaded coastline archive is invalid."

    safe_extract_zip "$archive" "$extract_dir"

    source_shp="$(find "$extract_dir" -type f -name 'water_polygons.shp' -print -quit)"
    [ -n "$source_shp" ] || die "Coastline archive does not contain water_polygons.shp."

    source_dir="$(dirname "$source_shp")"

    rm -rf "$COASTLINE_DIR"
    mkdir -p "$COASTLINE_DIR"
    cp -a "$source_dir"/. "$COASTLINE_DIR"/

    rm -rf "$extract_dir"
    rm -f "$archive"

    [ -s "$COASTLINE_DIR/water_polygons.shp" ] \
        || die "Coastline installation validation failed."
}

install_natural_earth_dataset() {
    local url="$1"
    local dataset="$2"

    local archive="$DOWNLOADS_DIR/${dataset}.zip.part"
    local extract_dir="$DOWNLOADS_DIR/${dataset}-extract.$$"
    local destination="$LANDCOVER_DIR/$dataset"
    local source_shp
    local source_dir

    download_resumable \
        "$url" \
        "$archive" \
        "Downloading Natural Earth dataset: $dataset"

    require_command unzip
    unzip -tq "$archive" >/dev/null \
        || die "Downloaded Natural Earth archive '$dataset' is invalid."

    safe_extract_zip "$archive" "$extract_dir"

    source_shp="$(find "$extract_dir" -type f -name "${dataset}.shp" -print -quit)"
    [ -n "$source_shp" ] \
        || die "Natural Earth archive does not contain ${dataset}.shp."

    source_dir="$(dirname "$source_shp")"

    rm -rf "$destination"
    mkdir -p "$destination"
    cp -a "$source_dir"/. "$destination"/

    rm -rf "$extract_dir"
    rm -f "$archive"

    [ -s "$destination/${dataset}.shp" ] \
        || die "Natural Earth installation validation failed for '$dataset'."
}

ensure_tilemaker_data() {
    section "Checking Tilemaker coastline / landcover data"

    if auxiliary_data_ready; then
        success "Tilemaker auxiliary datasets are ready."
        return 0
    fi

    warn "Tilemaker auxiliary datasets are missing or incomplete."

    require_command curl
    require_command unzip

    if [ ! -s "$COASTLINE_DIR/water_polygons.shp" ] \
        || [ ! -s "$COASTLINE_DIR/water_polygons.dbf" ] \
        || [ ! -s "$COASTLINE_DIR/water_polygons.shx" ]
    then
        install_coastline
    fi

    if [ ! -s "$LANDCOVER_DIR/ne_10m_urban_areas/ne_10m_urban_areas.shp" ]; then
        install_natural_earth_dataset \
            "$NATURAL_EARTH_URBAN_URL" \
            "ne_10m_urban_areas"
    fi

    if [ ! -s "$LANDCOVER_DIR/ne_10m_antarctic_ice_shelves_polys/ne_10m_antarctic_ice_shelves_polys.shp" ]; then
        install_natural_earth_dataset \
            "$NATURAL_EARTH_ICE_SHELF_URL" \
            "ne_10m_antarctic_ice_shelves_polys"
    fi

    if [ ! -s "$LANDCOVER_DIR/ne_10m_glaciated_areas/ne_10m_glaciated_areas.shp" ]; then
        install_natural_earth_dataset \
            "$NATURAL_EARTH_GLACIER_URL" \
            "ne_10m_glaciated_areas"
    fi

    auxiliary_data_ready \
        || die "Tilemaker auxiliary dataset installation is incomplete."

    success "Tilemaker coastline and landcover datasets installed."
}

# ==============================================================================
# Geofabrik Index
# ==============================================================================

fetch_geofabrik_index() {
    require_command curl
    require_command python3

    local temp_index="$GEOFABRIK_INDEX_FILE.tmp"

    info "Fetching Geofabrik region index..."

    if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 4 \
        --retry-delay 2 \
        --retry-connrefused \
        --connect-timeout 20 \
        --output "$temp_index" \
        "$GEOFABRIK_INDEX_URL"
    then
        rm -f "$temp_index"
        die "Unable to download Geofabrik index."
    fi

    if ! python3 -m json.tool "$temp_index" >/dev/null 2>&1; then
        rm -f "$temp_index"
        die "Geofabrik returned an invalid JSON index."
    fi

    mv -f "$temp_index" "$GEOFABRIK_INDEX_FILE"
    success "Geofabrik index loaded."
}

search_geofabrik() {
    local index_file="$1"
    local query="$2"
    local output="$3"

    python3 - "$index_file" "$query" > "$output" <<'PY'
import json
import sys

index_file = sys.argv[1]
query = sys.argv[2].strip().casefold()

with open(index_file, "r", encoding="utf-8") as f:
    data = json.load(f)

features = data.get("features", [])
props_by_id = {}

for feature in features:
    props = feature.get("properties", {})
    region_id = str(props.get("id", "") or "")
    if region_id:
        props_by_id[region_id] = props


def top_group(region_id):
    seen = set()
    current = region_id

    while current and current not in seen:
        seen.add(current)
        props = props_by_id.get(current, {})
        parent = str(props.get("parent", "") or "")

        if not parent:
            return current

        current = parent

    return region_id


matches = []

for feature in features:
    props = feature.get("properties", {})

    region_id = str(props.get("id", "") or "")
    name = str(props.get("name", "") or "")
    parent = str(props.get("parent", "") or "")
    url = props.get("urls", {}).get("pbf")

    if not region_id or not name or not url:
        continue

    iso1 = props.get("iso3166-1:alpha2", []) or []
    iso2 = props.get("iso3166-2", []) or []

    if isinstance(iso1, str):
        iso1 = [iso1]
    if isinstance(iso2, str):
        iso2 = [iso2]

    iso_codes = [str(item) for item in (iso1 + iso2)]
    group = top_group(region_id)
    kind = "country" if iso1 else "region"

    haystack = " ".join([name, region_id, parent, group, *iso_codes]).casefold()

    if query not in haystack:
        continue

    name_cf = name.casefold()
    id_cf = region_id.casefold()
    iso_cf = [item.casefold() for item in iso_codes]

    if query == name_cf or query == id_cf or query in iso_cf:
        score = 0
    elif name_cf.startswith(query):
        score = 1
    elif id_cf.startswith(query):
        score = 2
    else:
        score = 3

    matches.append((score, name_cf, name, region_id, parent, group, kind, url))

matches.sort()

for _, _, name, region_id, parent, group, kind, url in matches[:50]:
    print(f"{name}\t{region_id}\t{parent}\t{group}\t{kind}\t{url}")
PY
}

# ==============================================================================
# Source Overlap Guard
# ==============================================================================

check_source_hierarchy_conflict() {
    local selected_id="$1"
    local selected_group="$2"

    require_command python3

    python3 - \
        "$GEOFABRIK_INDEX_FILE" \
        "$SOURCES_DIR" \
        "$selected_id" \
        "$selected_group" <<'PY'
import json
import sys
from pathlib import Path

index_file = Path(sys.argv[1])
sources_dir = Path(sys.argv[2])
selected_id = sys.argv[3]
selected_group = sys.argv[4]

with index_file.open("r", encoding="utf-8") as f:
    data = json.load(f)

parents = {}
for feature in data.get("features", []):
    props = feature.get("properties", {})
    rid = str(props.get("id", "") or "")
    if rid:
        parents[rid] = str(props.get("parent", "") or "")


def ancestors(region_id):
    result = set()
    current = region_id
    seen = set()

    while current and current not in seen:
        seen.add(current)
        parent = parents.get(current, "")
        if not parent:
            break
        result.add(parent)
        current = parent

    return result

selected_ancestors = ancestors(selected_id)
conflicts = []

group_dir = sources_dir / selected_group
if group_dir.exists():
    for meta_file in group_dir.glob("*.source.json"):
        try:
            meta = json.loads(meta_file.read_text(encoding="utf-8"))
        except Exception:
            continue

        existing_id = str(meta.get("id", "") or "")
        if not existing_id or existing_id == selected_id:
            continue

        existing_ancestors = ancestors(existing_id)

        if existing_id in selected_ancestors or selected_id in existing_ancestors:
            conflicts.append(existing_id)

if conflicts:
    print(", ".join(sorted(conflicts)))
    sys.exit(2)
PY
}

# ==============================================================================
# Geofabrik Source Download
# ==============================================================================

download_geofabrik_source() {
    local region_name="$1"
    local region_id="$2"
    local parent="$3"
    local shard="$4"
    local kind="$5"
    local url="$6"

    local shard_dir="$SOURCES_DIR/$shard"
    local destination="$shard_dir/$region_id.osm.pbf"
    local checksum_file="$shard_dir/$region_id.checksum"
    local metadata_file="$shard_dir/$region_id.source.json"

    local partial="$DOWNLOADS_DIR/${shard}-${region_id}.osm.pbf.part"
    local remote_md5_file="$DOWNLOADS_DIR/${shard}-${region_id}.md5"

    local expected_md5=""
    local actual_checksum=""
    local checksum_type=""
    local conflict_output=""

    mkdir -p "$shard_dir"

    if conflict_output="$(check_source_hierarchy_conflict "$region_id" "$shard" 2>/dev/null)"; then
        true
    else
        local conflict_status=$?

        if [ "$conflict_status" -eq 2 ]; then
            die "'$region_id' overlaps a parent/child Geofabrik extract already stored in shard '$shard': $conflict_output. Remove the overlapping source first."
        fi

        die "Unable to validate source hierarchy for '$region_id'."
    fi

    section "Geofabrik source download"

    printf 'Region : %s\n' "$region_name" >&2
    printf 'ID     : %s\n' "$region_id" >&2
    printf 'Type   : %s\n' "$kind" >&2
    printf 'Shard  : %s\n' "$shard" >&2
    printf 'Source : %s\n\n' "$url" >&2

    if [ "$kind" != "country" ]; then
        warn "This is a Geofabrik region extract, not a country-level extract."
        warn "Do not combine geographically overlapping special regions in the same shard."
    fi

    info "Checking remote MD5 checksum..."

    if curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --output "$remote_md5_file" \
        "${url}.md5"
    then
        expected_md5="$(awk '{print $1}' "$remote_md5_file" | head -n1)"

        if [[ "$expected_md5" =~ ^[0-9A-Fa-f]{32}$ ]]; then
            require_command md5sum
            checksum_type="md5"
            success "Remote checksum found."
        else
            expected_md5=""
            rm -f "$remote_md5_file"
            warn "Remote checksum format was invalid."
        fi
    else
        rm -f "$remote_md5_file"
        warn "Remote checksum was not available; SHA-256 will be calculated locally."
    fi

    # Fast path: if Geofabrik reports the same MD5 we already verified earlier,
    # avoid downloading the full source again.
    if [ -n "$expected_md5" ]         && [ -s "$destination" ]         && [ -s "$checksum_file" ]         && [ "$(cat "$checksum_file")" = "md5:${expected_md5}" ]
    then
        rm -f "$remote_md5_file" "$partial"
        success "Source is already current: $region_id"
        return 0
    fi

    if ! download_resumable "$url" "$partial" "Downloading $region_name"; then
        if [ -n "$expected_md5" ] && [ -s "$partial" ]; then
            actual_checksum="$(md5sum "$partial" | awk '{print $1}')"

            if [ "$actual_checksum" = "$expected_md5" ]; then
                warn "curl returned an error, but MD5 confirms the file is complete."
            else
                warn "Resumed partial file does not match the current remote checksum."
                info "Retrying once from zero..."
                rm -f "$partial"

                download_resumable "$url" "$partial" "Re-downloading $region_name from zero" \
                    || die "Download failed. Partial file was preserved for retry."
            fi
        else
            die "Download failed. Partial file was preserved for retry."
        fi
    fi

    [ -s "$partial" ] || die "Downloaded PBF file is empty."

    if [ -n "$expected_md5" ]; then
        info "Verifying downloaded map..."

        actual_checksum="$(md5sum "$partial" | awk '{print $1}')"

        if [ "$actual_checksum" != "$expected_md5" ]; then
            warn "Checksum mismatch. Retrying once from zero..."
            rm -f "$partial"

            download_resumable "$url" "$partial" "Re-downloading $region_name from zero" \
                || die "Unable to download map."

            actual_checksum="$(md5sum "$partial" | awk '{print $1}')"

            if [ "$actual_checksum" != "$expected_md5" ]; then
                rm -f "$partial"
                die "Checksum still does not match."
            fi
        fi

        success "MD5 checksum verified."
    else
        require_command sha256sum
        checksum_type="sha256"
        actual_checksum="$(sha256sum "$partial" | awk '{print $1}')"
        success "Local SHA-256 calculated."
    fi

    if [ -f "$checksum_file" ] \
        && [ -f "$destination" ] \
        && [ "$(cat "$checksum_file")" = "${checksum_type}:${actual_checksum}" ]
    then
        rm -f "$partial" "$remote_md5_file"
        success "Source is already current: $region_id"
    else
        mv -f "$partial" "$destination"
        printf '%s:%s\n' "$checksum_type" "$actual_checksum" > "$checksum_file"

        python3 - \
            "$metadata_file" \
            "$region_name" \
            "$region_id" \
            "$parent" \
            "$shard" \
            "$kind" \
            "$url" \
            "$checksum_type" \
            "$actual_checksum" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out = Path(sys.argv[1])

payload = {
    "name": sys.argv[2],
    "id": sys.argv[3],
    "parent": sys.argv[4],
    "shard": sys.argv[5],
    "kind": sys.argv[6],
    "url": sys.argv[7],
    "checksum_type": sys.argv[8],
    "checksum": sys.argv[9],
    "downloaded_at": datetime.now(timezone.utc).isoformat(),
}

out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

        success "Source installed: $destination"
    fi

    rm -f "$remote_md5_file"

    DOWNLOAD_COMPLETED=true
    DOWNLOADED_SHARD="$shard"
}

# ==============================================================================
# Interactive Geofabrik Menu
# ==============================================================================

geofabrik_download_menu() {
    local initial_query="${1:-}"
    local results_file="$DOWNLOADS_DIR/geofabrik-results.tsv"
    local query="$initial_query"
    local choice

    local selected_name
    local selected_id
    local selected_parent
    local selected_group
    local selected_kind
    local selected_url

    local row_name
    local row_id
    local row_parent
    local row_group
    local row_kind
    local row_url

    local i
    local confirm=""

    require_command python3

    section "Geofabrik Map Downloader"
    fetch_geofabrik_index

    while true; do
        if [ -z "$query" ]; then
            printf '\nSearch examples:\n  Iran\n  Finland\n  Germany\n  Japan\n  FI\n\n' >&2

            if ! read -r -p "Search country / region (q = cancel): " query; then
                return 0
            fi
        fi

        if [ "$query" = "q" ] || [ "$query" = "Q" ]; then
            info "Download cancelled."
            return 0
        fi

        search_geofabrik "$GEOFABRIK_INDEX_FILE" "$query" "$results_file"
        mapfile -t results < "$results_file"

        if [ "${#results[@]}" -eq 0 ]; then
            warn "No Geofabrik region matched '$query'."
            query=""
            continue
        fi

        printf '\n%sMatching regions:%s\n\n' "$COLOR_CYAN" "$COLOR_RESET" >&2

        for i in "${!results[@]}"; do
            IFS=$'\t' read -r \
                row_name \
                row_id \
                row_parent \
                row_group \
                row_kind \
                row_url \
                <<< "${results[$i]}"

            printf '  %2d) %-32s [%s | shard=%s | %s]\n' \
                "$((i + 1))" \
                "$row_name" \
                "$row_id" \
                "$row_group" \
                "$row_kind" \
                >&2
        done

        printf '\n   0) Search again\n   q) Cancel\n\n' >&2

        if ! read -r -p "Select region: " choice; then
            return 0
        fi

        if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
            info "Download cancelled."
            return 0
        fi

        if [ "$choice" = "0" ]; then
            query=""
            continue
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] \
            || [ "$choice" -lt 1 ] \
            || [ "$choice" -gt "${#results[@]}" ]
        then
            warn "Invalid selection."
            continue
        fi

        IFS=$'\t' read -r \
            selected_name \
            selected_id \
            selected_parent \
            selected_group \
            selected_kind \
            selected_url \
            <<< "${results[$((choice - 1))]}"

        printf '\n%sSelected:%s\n' "$COLOR_GREEN" "$COLOR_RESET" >&2
        printf '  Name : %s\n' "$selected_name" >&2
        printf '  ID   : %s\n' "$selected_id" >&2
        printf '  Shard: %s\n' "$selected_group" >&2
        printf '  URL  : %s\n\n' "$selected_url" >&2

        confirm=""
        if ! read -r -p "Download this source? [Y/n]: " confirm; then
            return 0
        fi

        case "$confirm" in
            n|N|no|NO)
                query=""
                continue
                ;;
        esac

        download_geofabrik_source \
            "$selected_name" \
            "$selected_id" \
            "$selected_parent" \
            "$selected_group" \
            "$selected_kind" \
            "$selected_url"

        break
    done

    rm -f "$results_file"
}

# ==============================================================================
# Manual Source Import
# ==============================================================================

import_source() {
    local shard="$1"
    local source_path="$2"
    local region_id="$3"

    [[ "$shard" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid shard name: $shard"
    [[ "$region_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid source id: $region_id"
    [ -s "$source_path" ] || die "Source PBF does not exist or is empty: $source_path"

    require_command sha256sum
    require_command python3

    local shard_dir="$SOURCES_DIR/$shard"
    local destination="$shard_dir/$region_id.osm.pbf"
    local temp_destination="$shard_dir/.$region_id.importing.osm.pbf"
    local checksum_file="$shard_dir/$region_id.checksum"
    local metadata_file="$shard_dir/$region_id.source.json"
    local checksum

    mkdir -p "$shard_dir"
    info "Importing manual source into shard '$shard'..."

    cp -f "$source_path" "$temp_destination"
    checksum="$(sha256sum "$temp_destination" | awk '{print $1}')"
    mv -f "$temp_destination" "$destination"
    printf 'sha256:%s\n' "$checksum" > "$checksum_file"

    python3 - "$metadata_file" "$region_id" "$shard" "$source_path" "$checksum" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

out = Path(sys.argv[1])
payload = {
    "name": sys.argv[2],
    "id": sys.argv[2],
    "parent": "",
    "shard": sys.argv[3],
    "kind": "manual",
    "url": "",
    "imported_from": sys.argv[4],
    "checksum_type": "sha256",
    "checksum": sys.argv[5],
    "downloaded_at": datetime.now(timezone.utc).isoformat(),
}
out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

    success "Imported: $destination"
    warn "Manual imports are not checked against Geofabrik hierarchy. Avoid overlapping extracts."
}

# ==============================================================================
# Source Listing / Removal
# ==============================================================================

list_sources() {
    section "Stored map sources"

    require_command python3

    python3 - "$SOURCES_DIR" "$TILES_DIR" <<'PY'
import json
import sys
from pathlib import Path

sources_dir = Path(sys.argv[1])
tiles_dir = Path(sys.argv[2])

found = False

for shard_dir in sorted(p for p in sources_dir.iterdir() if p.is_dir()):
    rows = []

    for meta_file in sorted(shard_dir.glob("*.source.json")):
        try:
            meta = json.loads(meta_file.read_text(encoding="utf-8"))
        except Exception:
            continue

        pbf = shard_dir / f"{meta.get('id', '')}.osm.pbf"
        if not pbf.is_file():
            continue

        rows.append((meta.get("id", "?"), meta.get("name", "?"), pbf.stat().st_size))

    if not rows:
        continue

    found = True
    tile = tiles_dir / f"{shard_dir.name}.mbtiles"
    tile_status = "built" if tile.is_file() else "not-built"

    print(f"{shard_dir.name} [{tile_status}]")
    for region_id, name, size in rows:
        print(f"  - {region_id:24} {name} ({size / 1024 / 1024:.1f} MiB)")

if not found:
    print("No managed sources found.")
PY
}

remove_source() {
    local region_id="$1"
    local found=false
    local metadata_file
    local source_file
    local checksum_file
    local shard=""

    shopt -s nullglob

    for metadata_file in "$SOURCES_DIR"/*/"$region_id.source.json"; do
        [ -f "$metadata_file" ] || continue

        found=true
        shard="$(basename "$(dirname "$metadata_file")")"
        source_file="$(dirname "$metadata_file")/$region_id.osm.pbf"
        checksum_file="$(dirname "$metadata_file")/$region_id.checksum"

        rm -f "$metadata_file" "$source_file" "$checksum_file"

        success "Removed source '$region_id' from shard '$shard'."
    done

    shopt -u nullglob

    [ "$found" = true ] || die "Source '$region_id' was not found."

    if ! find "$SOURCES_DIR/$shard" -maxdepth 1 -type f -name '*.osm.pbf' -print -quit | grep -q .; then
        warn "Shard '$shard' now has no sources. Its generated MBTiles will be removed during sync."
    fi
}

# ==============================================================================
# Build Fingerprint / MBTiles Validation
# ==============================================================================

shard_fingerprint() {
    local shard="$1"
    local shard_dir="$SOURCES_DIR/$shard"
    local pbf
    local checksum

    require_command sha256sum

    {
        printf 'tilemaker=%s\n' "$TILEMAKER_IMAGE"
        printf 'extra=%s\n' "$TILEMAKER_EXTRA_ARGS"

        sha256sum \
            "$CONFIG_DIR/config-openmaptiles.json" \
            "$CONFIG_DIR/process-openmaptiles.lua"

        for pbf in "$shard_dir"/*.osm.pbf; do
            [ -e "$pbf" ] || continue

            checksum="${pbf%.osm.pbf}.checksum"

            if [ -s "$checksum" ]; then
                printf '%s %s\n' "$(basename "$pbf")" "$(cat "$checksum")"
            else
                printf '%s size=%s mtime=%s\n' \
                    "$(basename "$pbf")" \
                    "$(stat -c '%s' "$pbf")" \
                    "$(stat -c '%Y' "$pbf")"
            fi
        done

        for pbf in \
            "$COASTLINE_DIR/water_polygons.shp" \
            "$LANDCOVER_DIR/ne_10m_urban_areas/ne_10m_urban_areas.shp" \
            "$LANDCOVER_DIR/ne_10m_antarctic_ice_shelves_polys/ne_10m_antarctic_ice_shelves_polys.shp" \
            "$LANDCOVER_DIR/ne_10m_glaciated_areas/ne_10m_glaciated_areas.shp"
        do
            printf '%s size=%s mtime=%s\n' \
                "$pbf" \
                "$(stat -c '%s' "$pbf")" \
                "$(stat -c '%Y' "$pbf")"
        done
    } | sha256sum | awk '{print $1}'
}

validate_mbtiles() {
    local mbtiles="$1"

    require_command python3

    python3 - "$mbtiles" <<'PY'
import sqlite3
import sys
from pathlib import Path

path = Path(sys.argv[1])

if not path.is_file() or path.stat().st_size <= 0:
    raise SystemExit(1)

conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)

objects = {
    row[0]
    for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
    )
}

if "metadata" not in objects or "tiles" not in objects:
    conn.close()
    raise SystemExit(2)

row = conn.execute("SELECT 1 FROM tiles LIMIT 1").fetchone()
metadata = dict(conn.execute("SELECT name, value FROM metadata"))
conn.close()

if not row:
    raise SystemExit(3)

if metadata.get("format") not in (None, "pbf"):
    raise SystemExit(4)

print("valid")
PY
}

# ==============================================================================
# Shard Discovery / Build
# ==============================================================================

managed_source_shards() {
    local shard_dir

    shopt -s nullglob

    for shard_dir in "$SOURCES_DIR"/*/; do
        [ -d "$shard_dir" ] || continue

        if find "$shard_dir" -maxdepth 1 -type f -name '*.osm.pbf' -print -quit | grep -q .; then
            basename "$shard_dir"
        fi
    done

    shopt -u nullglob
}

cleanup_empty_managed_shards() {
    local state_file
    local shard
    local shard_dir
    local tile_file

    shopt -s nullglob

    for state_file in "$STATE_DIR"/*.sha256; do
        [ -f "$state_file" ] || continue

        shard="$(basename "$state_file" .sha256)"
        shard_dir="$SOURCES_DIR/$shard"
        tile_file="$TILES_DIR/$shard.mbtiles"

        if ! find "$shard_dir" -maxdepth 1 -type f -name '*.osm.pbf' -print -quit 2>/dev/null | grep -q .; then
            warn "Removing empty managed shard '$shard'."
            rm -f "$tile_file" "$state_file"
            rm -rf "$shard_dir"
            CONFIG_CHANGED=true
            SERVER_RESTART_REQUIRED=true
        fi
    done

    shopt -u nullglob
}

build_shard() {
    local shard="$1"
    local force="${2:-false}"

    local shard_dir="$SOURCES_DIR/$shard"
    local output="$TILES_DIR/$shard.mbtiles"
    local temp_output="$TILES_DIR/.$shard.building.mbtiles"
    local state_file="$STATE_DIR/$shard.sha256"
    local store="$STORE_DIR/$shard"

    local fingerprint
    local old_fingerprint=""
    local tile_count

    local source_files=()
    local container_input_args=()
    local extra_args=()
    local pbf

    shopt -s nullglob
    source_files=("$shard_dir"/*.osm.pbf)
    shopt -u nullglob

    if [ "${#source_files[@]}" -eq 0 ]; then
        warn "Shard '$shard' has no source PBF files."
        return 0
    fi

    fingerprint="$(shard_fingerprint "$shard")"

    if [ -s "$state_file" ]; then
        old_fingerprint="$(cat "$state_file")"
    fi

    if [ "$force" != true ] \
        && [ -s "$output" ] \
        && [ "$fingerprint" = "$old_fingerprint" ]
    then
        success "Shard is current: $shard (${#source_files[@]} source(s))"
        return 0
    fi

    section "Building shard: $shard"

    require_command docker

    printf 'Sources: %d\n' "${#source_files[@]}" >&2
    printf 'Output : %s\n' "$output" >&2
    printf 'Image  : %s\n\n' "$TILEMAKER_IMAGE" >&2

    for pbf in "${source_files[@]}"; do
        # Do not pass multiple PBFs as bare positional arguments. Tilemaker
        # treats positional argument #1 as input and #2 as output. Every PBF
        # must therefore be an explicit --input occurrence.
        container_input_args+=(
            --input
            "/data/sources/$shard/$(basename "$pbf")"
        )
        printf '  - %s\n' "$(basename "$pbf")" >&2
    done

    if [ "${#source_files[@]}" -gt 1 ]; then
        verify_tilemaker_multi_input_support
    fi

    printf '\n' >&2

    if [ -n "$TILEMAKER_EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206
        extra_args=($TILEMAKER_EXTRA_ARGS)
    fi

    rm -f "$temp_output"
    rm -rf "$store"
    mkdir -p "$store"

    # Tilemaker officially supports multiple PBFs in one run. We intentionally
    # rebuild the shard from all current sources instead of using --merge, so a
    # failed/updated source cannot leave duplicated old tile content behind.
    if docker run --rm \
        -v "$MAPS_DIR":/data \
        -v "$CONFIG_DIR":/config:ro \
        -w /config \
        "$TILEMAKER_IMAGE" \
        "${container_input_args[@]}" \
        --output "/data/tiles/$(basename "$temp_output")" \
        --process /config/process-openmaptiles.lua \
        --config /config/config-openmaptiles.json \
        --store "/data/temp_store/$shard" \
        "${extra_args[@]}"
    then
        if ! tile_count="$(validate_mbtiles "$temp_output")"; then
            rm -f "$temp_output"
            rm -rf "$store"
            CONVERSION_FAILED=true
            error "Generated shard failed MBTiles validation: $shard"
            return 1
        fi

        mv -f "$temp_output" "$output"
        printf '%s\n' "$fingerprint" > "$state_file"
        rm -rf "$store"

        CONFIG_CHANGED=true
        SERVER_RESTART_REQUIRED=true

        success "Shard built successfully: $shard"
    else
        rm -f "$temp_output"
        rm -rf "$store"
        CONVERSION_FAILED=true

        error "Shard build failed: $shard"
        warn "Existing production MBTiles was preserved."
        return 1
    fi
}

build_all_dirty_shards() {
    local force_target="${1:-}"
    local shard
    local found=false

    section "Checking map shards"

    cleanup_empty_managed_shards

    while IFS= read -r shard; do
        [ -n "$shard" ] || continue
        found=true

        if [ -n "$force_target" ] \
            && [ "$force_target" != "all" ] \
            && [ "$force_target" != "$shard" ]
        then
            continue
        fi

        if [ "$force_target" = "all" ] || [ "$force_target" = "$shard" ]; then
            if ! build_shard "$shard" true; then
                true
            fi
        else
            if ! build_shard "$shard" false; then
                true
            fi
        fi
    done < <(managed_source_shards)

    if [ "$found" = false ]; then
        warn "No managed source PBF files exist yet."
    fi

    if [ -n "$force_target" ] \
        && [ "$force_target" != "all" ] \
        && [ ! -d "$SOURCES_DIR/$force_target" ]
    then
        die "Unknown shard '$force_target'. Use './map_manager.sh list'."
    fi
}

# ==============================================================================
# OpenMapTiles Style Catalog / Installer
#
# Standalone OpenMapTiles GL style repositories with ready style.json + sprites.
# The upstream OSM OpenMapTiles style itself is build-generated, so it is not
# included in the one-command catalog.
# ==============================================================================

STYLE_CATALOG_PAGE="https://openmaptiles.org/#map-styles"

style_catalog_rows() {
    cat <<'STYLE_CATALOG_EOF'
osm-bright|OSM Bright|https://openmaptiles.org/styles/osm-bright/|https://raw.githubusercontent.com/openmaptiles/osm-bright-gl-style/master/style.json
positron|Positron|https://openmaptiles.org/styles/positron/|https://raw.githubusercontent.com/openmaptiles/positron-gl-style/master/style.json
dark-matter|Dark Matter|https://openmaptiles.org/styles/dark-matter/|https://raw.githubusercontent.com/openmaptiles/dark-matter-gl-style/master/style.json
fiord-color|Fiord Color|https://openmaptiles.org/styles/fiord-color/|https://raw.githubusercontent.com/openmaptiles/fiord-color-gl-style/master/style.json
maptiler-basic|MapTiler Basic|https://openmaptiles.org/styles/maptiler-basic/|https://raw.githubusercontent.com/openmaptiles/maptiler-basic-gl-style/master/style.json
STYLE_CATALOG_EOF
}

style_catalog_lookup() {
    local wanted="$1"
    local style_id style_name preview_url style_url

    while IFS='|' read -r style_id style_name preview_url style_url; do
        if [ "$style_id" = "$wanted" ]; then
            printf '%s|%s|%s|%s\n' "$style_id" "$style_name" "$preview_url" "$style_url"
            return 0
        fi
    done < <(style_catalog_rows)

    return 1
}

list_styles() {
    section "OpenMapTiles style catalog"

    printf 'Browse all OpenMapTiles styles:\n  %s\n\n' "$STYLE_CATALOG_PAGE" >&2
    printf 'Supported one-command styles:\n\n' >&2

    local style_id style_name preview_url style_url status

    while IFS='|' read -r style_id style_name preview_url style_url; do
        if [ -s "$STYLES_DIR/$style_id/style.json" ]; then
            status="installed"
        else
            status="not-installed"
        fi

        printf '  %-16s %-20s [%s]\n' "$style_id" "$style_name" "$status" >&2
        printf '    Preview: %s\n' "$preview_url" >&2
    done < <(style_catalog_rows)

    printf '\nInstalled source styles:\n\n' >&2

    local found=false
    local style_path

    for style_path in "$STYLES_DIR"/*/; do
        [ -d "$style_path" ] || continue
        [ -s "$style_path/style.json" ] || continue
        found=true
        printf '  - %s\n' "$(basename "$style_path")" >&2
    done

    if [ "$found" = false ]; then
        printf '  (none)\n' >&2
    fi
}

download_style_asset() {
    local url="$1"
    local output="$2"
    local description="$3"

    require_command curl

    info "$description"

    if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 4 \
        --retry-delay 2 \
        --retry-connrefused \
        --connect-timeout 20 \
        --output "$output" \
        "$url"
    then
        rm -f "$output"
        return 1
    fi

    [ -s "$output" ] || {
        rm -f "$output"
        return 1
    }
}

validate_downloaded_style() {
    local style_file="$1"

    require_command python3

    python3 - "$style_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])

try:
    style = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"Invalid style JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if style.get("version") != 8:
    print("Style must use Mapbox/MapLibre Style Specification version 8.", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(style.get("sources"), dict) or not style["sources"]:
    print("Style has no sources.", file=sys.stderr)
    raise SystemExit(3)

if not isinstance(style.get("layers"), list) or not style["layers"]:
    print("Style has no layers.", file=sys.stderr)
    raise SystemExit(4)

vector_sources = [
    source
    for source in style["sources"].values()
    if isinstance(source, dict) and source.get("type") == "vector"
]

if not vector_sources:
    print("Style has no vector source compatible with this map server.", file=sys.stderr)
    raise SystemExit(5)
PY
}

validate_sprite_bundle() {
    local sprite_dir="$1"

    require_command python3

    python3 -m json.tool "$sprite_dir/sprite.json" >/dev/null 2>&1 || return 1
    python3 -m json.tool "$sprite_dir/sprite@2x.json" >/dev/null 2>&1 || return 1

    python3 - "$sprite_dir/sprite.png" "$sprite_dir/sprite@2x.png" <<'PY'
import sys
from pathlib import Path

signature = b"\x89PNG\r\n\x1a\n"

for filename in sys.argv[1:]:
    path = Path(filename)
    if not path.is_file() or path.stat().st_size <= 8:
        raise SystemExit(1)
    with path.open("rb") as f:
        if f.read(8) != signature:
            raise SystemExit(2)
PY
}

install_catalog_style() {
    local requested_id="$1"
    local assume_yes="${2:-false}"

    local row
    local style_id style_name preview_url style_url
    local confirm=""

    row="$(style_catalog_lookup "$requested_id" 2>/dev/null)" \
        || die "Unknown style '$requested_id'. Run './map_manager.sh style list'."

    IFS='|' read -r style_id style_name preview_url style_url <<< "$row"

    section "OpenMapTiles style: $style_name"

    printf 'Browse catalog : %s\n' "$STYLE_CATALOG_PAGE" >&2
    printf 'Preview        : %s\n' "$preview_url" >&2
    printf 'Style source   : %s\n\n' "$style_url" >&2

    if [ "$assume_yes" != true ]; then
        if [ -s "$STYLES_DIR/$style_id/style.json" ]; then
            read -r -p "Style '$style_id' is already installed. Update it? [y/N]: " confirm
        else
            read -r -p "Install this style locally? [y/N]: " confirm
        fi

        case "$confirm" in
            y|Y|yes|YES)
                ;;
            *)
                info "Style installation cancelled."
                return 0
                ;;
        esac
    fi

    require_command curl
    require_command python3

    local temp_root="$DOWNLOADS_DIR/style-${style_id}-$$"
    local temp_style="$temp_root/style.json"
    local temp_sprites="$temp_root/sprites"
    local sprite_url=""
    local suffix

    rm -rf "$temp_root"
    mkdir -p "$temp_sprites"

    download_style_asset "$style_url" "$temp_style" "Downloading style.json" \
        || {
            rm -rf "$temp_root"
            die "Unable to download style '$style_id'."
        }

    validate_downloaded_style "$temp_style" \
        || {
            rm -rf "$temp_root"
            die "Downloaded style '$style_id' failed validation."
        }

    sprite_url="$(python3 - "$temp_style" <<'PY'
import json
import sys
from pathlib import Path

style = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
sprite = style.get("sprite", "")
print(sprite if isinstance(sprite, str) else "")
PY
)"

    if [ -n "$sprite_url" ]; then
        case "$sprite_url" in
            http://*|https://*)
                ;;
            *)
                rm -rf "$temp_root"
                die "Style '$style_id' uses an unsupported sprite URL: $sprite_url"
                ;;
        esac

        for suffix in ".json" ".png" "@2x.json" "@2x.png"; do
            download_style_asset \
                "${sprite_url}${suffix}" \
                "$temp_sprites/sprite${suffix}" \
                "Downloading sprite${suffix}" \
                || {
                    rm -rf "$temp_root"
                    die "Unable to download sprite asset '${sprite_url}${suffix}'."
                }
        done

        validate_sprite_bundle "$temp_sprites" \
            || {
                rm -rf "$temp_root"
                die "Downloaded sprite bundle for '$style_id' failed validation."
            }
    fi

    local style_target_dir="$STYLES_DIR/$style_id"
    local style_temp_file="$style_target_dir/.style.json.install.$$"
    local style_backup_file="$style_target_dir/.style.json.backup.$$"
    local sprite_target_dir="$SPRITES_DIR/$style_id"
    local sprite_new_dir="$SPRITES_DIR/.${style_id}.install.$$"
    local sprite_backup_dir="$SPRITES_DIR/.${style_id}.backup.$$"

    mkdir -p "$style_target_dir"

    rm -f "$style_temp_file" "$style_backup_file"
    cp -f "$temp_style" "$style_temp_file"

    if [ -f "$style_target_dir/style.json" ]; then
        cp -p "$style_target_dir/style.json" "$style_backup_file"
    fi

    mv -f "$style_temp_file" "$style_target_dir/style.json"

    if [ -n "$sprite_url" ]; then
        rm -rf "$sprite_new_dir" "$sprite_backup_dir"
        mkdir -p "$sprite_new_dir"
        cp -a "$temp_sprites"/. "$sprite_new_dir"/

        if [ -d "$sprite_target_dir" ]; then
            if ! mv "$sprite_target_dir" "$sprite_backup_dir"; then
                if [ -f "$style_backup_file" ]; then
                    mv -f "$style_backup_file" "$style_target_dir/style.json"
                fi
                rm -rf "$sprite_new_dir" "$temp_root"
                die "Unable to prepare existing sprite directory for '$style_id'."
            fi
        fi

        if mv "$sprite_new_dir" "$sprite_target_dir"; then
            rm -rf "$sprite_backup_dir"
        else
            rm -rf "$sprite_new_dir"
            if [ -d "$sprite_backup_dir" ]; then
                mv "$sprite_backup_dir" "$sprite_target_dir"
            fi
            if [ -f "$style_backup_file" ]; then
                mv -f "$style_backup_file" "$style_target_dir/style.json"
            fi
            rm -rf "$temp_root"
            die "Unable to install sprite directory for '$style_id'."
        fi
    fi

    rm -f "$style_backup_file"
    rm -rf "$temp_root"

    STYLE_CHANGED=true
    CONFIG_CHANGED=true
    SERVER_RESTART_REQUIRED=true

    success "Style installed: $style_id"
    info "Source style : $style_target_dir/style.json"

    if [ -n "$sprite_url" ]; then
        info "Local sprites: $sprite_target_dir/"
    fi
}

style_install_menu() {
    local initial_id="${1:-}"
    local assume_yes="${2:-false}"

    if [ -n "$initial_id" ]; then
        install_catalog_style "$initial_id" "$assume_yes"
        return 0
    fi

    section "OpenMapTiles Style Installer"

    printf 'Browse/preview the official OpenMapTiles styles first:\n  %s\n\n' \
        "$STYLE_CATALOG_PAGE" >&2

    mapfile -t catalog < <(style_catalog_rows)

    local i
    local style_id style_name preview_url style_url
    local status
    local choice=""

    for i in "${!catalog[@]}"; do
        IFS='|' read -r style_id style_name preview_url style_url <<< "${catalog[$i]}"

        if [ -s "$STYLES_DIR/$style_id/style.json" ]; then
            status="installed"
        else
            status="not-installed"
        fi

        printf '  %2d) %-20s [%s]\n' "$((i + 1))" "$style_name" "$status" >&2
        printf '      %s\n' "$preview_url" >&2
    done

    printf '\n   q) Cancel\n\n' >&2

    if ! read -r -p "Select style: " choice; then
        return 0
    fi

    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        info "Style installation cancelled."
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] \
        || [ "$choice" -lt 1 ] \
        || [ "$choice" -gt "${#catalog[@]}" ]
    then
        die "Invalid style selection."
    fi

    IFS='|' read -r style_id style_name preview_url style_url \
        <<< "${catalog[$((choice - 1))]}"

    printf '\nSelected: %s\nPreview : %s\n\n' "$style_name" "$preview_url" >&2

    install_catalog_style "$style_id" "$assume_yes"
}

remove_style() {
    local style_id="$1"
    local assume_yes="${2:-false}"
    local style_dir="$STYLES_DIR/$style_id"
    local sprite_dir="$SPRITES_DIR/$style_id"
    local confirm=""

    [[ "$style_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid style id: $style_id"

    if [ ! -d "$style_dir" ] && [ ! -d "$sprite_dir" ]; then
        die "Style '$style_id' is not installed."
    fi

    section "Remove style: $style_id"

    if [ "$assume_yes" != true ]; then
        read -r -p "Delete the local style and matching sprites? [y/N]: " confirm

        case "$confirm" in
            y|Y|yes|YES)
                ;;
            *)
                info "Style removal cancelled."
                return 0
                ;;
        esac
    fi

    rm -rf "$style_dir" "$sprite_dir"

    STYLE_CHANGED=true
    CONFIG_CHANGED=true
    SERVER_RESTART_REQUIRED=true

    success "Style removed: $style_id"
}

# ==============================================================================
# Runtime Styles: one source per generated shard
# ==============================================================================

generate_runtime_styles() {
    section "Generating sharded offline styles"

    require_command python3

    local style_path
    local style_name
    local style_file
    local runtime_file
    local temp_runtime
    local found_style=false

    shopt -s nullglob
    local shard_files=("$TILES_DIR"/*.mbtiles)
    shopt -u nullglob

    if [ "${#shard_files[@]}" -eq 0 ]; then
        local removed_runtime=false

        for style_path in "$STYLES_DIR"/*/; do
            [ -d "$style_path" ] || continue

            runtime_file="$style_path/$RUNTIME_STYLE_FILE"
            temp_runtime="$runtime_file.tmp"

            if [ -e "$runtime_file" ] || [ -e "$temp_runtime" ]; then
                rm -f "$runtime_file" "$temp_runtime"
                removed_runtime=true
            fi
        done

        if [ "$removed_runtime" = true ]; then
            CONFIG_CHANGED=true
            SERVER_RESTART_REQUIRED=true
        fi

        warn "No generated shard MBTiles exist; runtime styles were removed."
        return 0
    fi

    for style_path in "$STYLES_DIR"/*/; do
        [ -d "$style_path" ] || continue

        style_file="$style_path/style.json"
        [ -f "$style_file" ] || continue

        found_style=true
        style_name="$(basename "$style_path")"
        runtime_file="$style_path/$RUNTIME_STYLE_FILE"
        temp_runtime="$runtime_file.tmp"

        if ! python3 - \
            "$style_file" \
            "$temp_runtime" \
            "$style_name" \
            "$TILES_DIR" <<'PY'
import copy
import json
import math
import sqlite3
import sys
from pathlib import Path

style_file = Path(sys.argv[1])
out_file = Path(sys.argv[2])
style_name = sys.argv[3]
tiles_dir = Path(sys.argv[4])

with style_file.open("r", encoding="utf-8") as f:
    style = json.load(f)

shards = sorted(path for path in tiles_dir.glob("*.mbtiles") if not path.name.startswith("."))

if not shards:
    raise SystemExit("No shard MBTiles files found")

if isinstance(style.get("glyphs"), str):
    style["glyphs"] = "{fontstack}/{range}.pbf"

if isinstance(style.get("sprite"), str):
    style["sprite"] = f"{style_name}/sprite"

sources = style.get("sources", {})
layers = style.get("layers", [])
used_sources = {layer.get("source") for layer in layers if layer.get("source")}

targets = []

# Prefer the legacy/generated basemap aliases when present.
for name, source in sources.items():
    if name not in used_sources or not isinstance(source, dict):
        continue
    url = str(source.get("url", ""))
    if source.get("type") == "vector" and url in ("mbtiles://{v3}", "mbtiles://{world}"):
        targets.append(name)

# For a newly added raw style, accept exactly one referenced remote vector source.
if not targets:
    remote_candidates = []
    for name, source in sources.items():
        if name not in used_sources or not isinstance(source, dict):
            continue
        url = str(source.get("url", ""))
        if source.get("type") == "vector" and (url.startswith("http://") or url.startswith("https://")):
            remote_candidates.append(name)

    if len(remote_candidates) == 1:
        targets = remote_candidates
    elif len(remote_candidates) > 1:
        raise SystemExit(
            f"Style {style_file} has multiple referenced remote vector sources; "
            "cannot safely guess which one is the basemap source."
        )

# Final fallback: exactly one referenced local MBTiles vector source.
if not targets:
    local_candidates = []
    for name, source in sources.items():
        if name not in used_sources or not isinstance(source, dict):
            continue
        url = str(source.get("url", ""))
        if source.get("type") == "vector" and url.startswith("mbtiles://"):
            local_candidates.append(name)

    if len(local_candidates) == 1:
        targets = local_candidates

if not targets:
    raise SystemExit(
        f"Could not identify one primary vector basemap source in {style_file}."
    )

new_sources = {}
source_map = {}

for name, source in sources.items():
    if name not in targets:
        new_sources[name] = copy.deepcopy(source)

for target in targets:
    base_source = copy.deepcopy(sources[target])
    source_map[target] = []

    for index, shard_path in enumerate(shards):
        shard_id = shard_path.stem
        runtime_source = f"{target}__shard_{index}"

        source = copy.deepcopy(base_source)
        source["type"] = "vector"
        source["url"] = f"mbtiles://{{{shard_id}}}"
        source.pop("tiles", None)

        new_sources[runtime_source] = source
        source_map[target].append((runtime_source, index, shard_id))

new_layers = []

for layer in layers:
    source_name = layer.get("source")

    if source_name in source_map:
        for runtime_source, index, shard_id in source_map[source_name]:
            clone = copy.deepcopy(layer)
            clone["id"] = f"{layer['id']}__shard_{index}"
            clone["source"] = runtime_source
            new_layers.append(clone)
    else:
        new_layers.append(copy.deepcopy(layer))

style["sources"] = new_sources
style["layers"] = new_layers

# Calculate the combined view from MBTiles metadata.
all_bounds = []

for shard_path in shards:
    try:
        conn = sqlite3.connect(f"file:{shard_path}?mode=ro", uri=True)
        row = conn.execute(
            "SELECT value FROM metadata WHERE name='bounds' LIMIT 1"
        ).fetchone()
        conn.close()

        if not row or not row[0]:
            continue

        parts = [float(item.strip()) for item in str(row[0]).strip().strip("[]").split(",")]

        if len(parts) == 4:
            all_bounds.append(parts)
    except Exception:
        pass

if all_bounds:
    west = min(bounds[0] for bounds in all_bounds)
    south = min(bounds[1] for bounds in all_bounds)
    east = max(bounds[2] for bounds in all_bounds)
    north = max(bounds[3] for bounds in all_bounds)

    style["center"] = [
        round((west + east) / 2, 6),
        round((south + north) / 2, 6),
    ]

    lon_span = max(east - west, 0.01)
    lat_span = max(north - south, 0.01)
    effective_span = max(lon_span, lat_span * 1.8)
    zoom = math.log2(360.0 / effective_span) - 0.6
    style["zoom"] = round(max(0.0, min(12.0, zoom)), 2)

with out_file.open("w", encoding="utf-8") as f:
    json.dump(style, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        then
            rm -f "$temp_runtime"
            die "Failed to generate runtime style for '$style_name'."
        fi

        if [ ! -f "$runtime_file" ] || ! cmp -s "$runtime_file" "$temp_runtime"; then
            mv -f "$temp_runtime" "$runtime_file"
            CONFIG_CHANGED=true
            SERVER_RESTART_REQUIRED=true
            success "Runtime style updated: $style_name (${#shard_files[@]} shard(s))"
        else
            rm -f "$temp_runtime"
            success "Runtime style is current: $style_name (${#shard_files[@]} shard(s))"
        fi
    done

    if [ "$found_style" = false ]; then
        warn "No source styles were found in $STYLES_DIR."
    fi
}

verify_runtime_styles_offline() {
    section "Checking runtime styles for remote dependencies"

    require_command python3

    if ! python3 - "$STYLES_DIR" "$RUNTIME_STYLE_FILE" <<'PY'
import json
import sys
from pathlib import Path

styles_dir = Path(sys.argv[1])
runtime_name = sys.argv[2]
errors = []

for path in sorted(styles_dir.glob(f"*/{runtime_name}")):
    try:
        style = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{path}: invalid JSON: {exc}")
        continue

    for key in ("glyphs", "sprite"):
        value = style.get(key)
        if isinstance(value, str) and value.startswith(("http://", "https://")):
            errors.append(f"{path}: remote {key}: {value}")

    sources = style.get("sources", {})
    if isinstance(sources, dict):
        for source_name, source in sources.items():
            if not isinstance(source, dict):
                continue

            url = source.get("url")
            if isinstance(url, str):
                if url.startswith(("http://", "https://")):
                    errors.append(f"{path}: source '{source_name}' has remote url: {url}")
                if url == "mbtiles://{v3}":
                    errors.append(f"{path}: source '{source_name}' still uses legacy v3")

            tiles = source.get("tiles", [])
            if isinstance(tiles, list):
                for tile_url in tiles:
                    if isinstance(tile_url, str) and tile_url.startswith(("http://", "https://")):
                        errors.append(
                            f"{path}: source '{source_name}' has remote tile URL: {tile_url}"
                        )

if errors:
    for item in errors:
        print(item, file=sys.stderr)
    raise SystemExit(1)
PY
    then
        die "Runtime styles still contain remote dependencies or the legacy v3 source."
    fi

    success "Runtime styles use only local shard/font/sprite resources."
}

# ==============================================================================
# TileServer Config
# ==============================================================================

generate_tileserver_config() {
    section "Generating TileServer configuration"

    require_command python3

    if ! python3 - \
        "$TILES_DIR" \
        "$STYLES_DIR" \
        "$TEMP_CONFIG" \
        "$RUNTIME_STYLE_FILE" <<'PY'
import json
import sys
from pathlib import Path

tiles_dir = Path(sys.argv[1])
styles_dir = Path(sys.argv[2])
out_file = Path(sys.argv[3])
runtime_style_name = sys.argv[4]

shards = sorted(path for path in tiles_dir.glob("*.mbtiles") if not path.name.startswith("."))

styles = {}
if styles_dir.exists():
    for directory in sorted(styles_dir.iterdir()):
        if not directory.is_dir():
            continue

        runtime_style = directory / runtime_style_name
        if runtime_style.is_file():
            styles[directory.name] = {
                "style": f"{directory.name}/{runtime_style_name}"
            }

data = {}
for path in shards:
    data[path.stem] = {"mbtiles": path.name}

# Legacy compatibility: v3 points to the first generated shard only.
# Generated styles never depend on v3.
if shards:
    data["v3"] = {"mbtiles": shards[0].name}

config = {
    "options": {
        "paths": {
            "root": "/data",
            "styles": "styles",
            "sprites": "sprites",
            "fonts": "fonts",
            "mbtiles": "tiles",
        },
    },
    "styles": styles,
    "data": data,
}

with out_file.open("w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    then
        rm -f "$TEMP_CONFIG"
        die "Failed to generate TileServer configuration."
    fi

    if [ ! -f "$TILESERVER_CONFIG" ] || ! cmp -s "$TILESERVER_CONFIG" "$TEMP_CONFIG"; then
        mv -f "$TEMP_CONFIG" "$TILESERVER_CONFIG"
        CONFIG_CHANGED=true
        SERVER_RESTART_REQUIRED=true
        success "TileServer configuration updated."
    else
        rm -f "$TEMP_CONFIG"
        success "TileServer configuration is already up to date."
    fi
}

# ==============================================================================
# TileServer / Docker Compose
# ==============================================================================

ensure_tileserver_running() {
    section "TileServer"

    require_command docker

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose plugin is not available."

    if [ "$SERVER_RESTART_REQUIRED" = true ] || [ "$CONFIG_CHANGED" = true ]; then
        info "Map/style configuration changed. Applying Docker Compose..."

        docker compose \
            --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" \
            up -d \
            --force-recreate

        success "TileServer configuration applied."
    else
        info "Ensuring TileServer is running..."

        docker compose \
            --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" \
            up -d

        success "TileServer is running."
    fi
}

# ==============================================================================
# Legacy Layout Cleanup
# ==============================================================================

cleanup_legacy_layout() {
    local assume_yes="${1:-false}"
    local legacy_files=()
    local file
    local confirm=""

    section "Cleaning legacy map layout"

    require_command python3

    shopt -s nullglob
    local shard_files=("$TILES_DIR"/*.mbtiles)
    shopt -u nullglob

    if [ "${#shard_files[@]}" -eq 0 ]; then
        die "No generated shard MBTiles exist. Build and verify the new architecture before cleanup."
    fi

    # Never delete legacy production data until config.json has actually
    # switched TileServer to maps/tiles.
    if ! python3 - "$TILESERVER_CONFIG" <<'PY_CHECK'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(1)

try:
    config = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

mbtiles_path = (
    config.get("options", {})
    .get("paths", {})
    .get("mbtiles")
)

if mbtiles_path != "tiles":
    raise SystemExit(1)

if not config.get("data"):
    raise SystemExit(1)
PY_CHECK
    then
        die "TileServer config is not using the sharded maps/tiles layout yet. Cleanup aborted."
    fi

    shopt -s nullglob

    legacy_files+=("$MAPS_DIR"/*.mbtiles)
    legacy_files+=("$MAPS_DIR"/*.osm.pbf)
    legacy_files+=("$MAPS_DIR"/*.osm)
    legacy_files+=("$MAPS_DIR"/*.pmtiles)
    legacy_files+=("$MAPS_DIR"/.*.building.mbtiles)

    shopt -u nullglob

    if [ -e "$MAPS_DIR/.default_map" ]; then
        legacy_files+=("$MAPS_DIR/.default_map")
    fi

    if [ -e "$TEMP_CONFIG" ]; then
        legacy_files+=("$TEMP_CONFIG")
    fi

    if [ "${#legacy_files[@]}" -eq 0 ]; then
        if [ -d "$STORE_DIR" ]; then
            find "$STORE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        fi

        success "No legacy map files remain."
        return 0
    fi

    printf 'The following legacy files are no longer used by the sharded configuration:\n\n' >&2

    for file in "${legacy_files[@]}"; do
        printf '  - %s\n' "$file" >&2
    done

    printf '\nThese files will be deleted only; managed sources and maps/tiles are preserved.\n\n' >&2

    if [ "$assume_yes" != true ]; then
        read -r -p "Delete these legacy files? [y/N]: " confirm

        case "$confirm" in
            y|Y|yes|YES)
                ;;
            *)
                info "Cleanup cancelled."
                return 0
                ;;
        esac
    fi

    rm -f -- "${legacy_files[@]}"

    if [ -d "$STORE_DIR" ]; then
        find "$STORE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi

    success "Legacy map files removed."
    success "Managed sources, generated shards, styles, fonts and config were preserved."
}

# ==============================================================================
# Full Synchronization
# ==============================================================================

sync_all() {
    local force_target="${1:-}"

    ensure_fonts
    ensure_tilemaker_data
    build_all_dirty_shards "$force_target"

    # Migration safety: if the new sharded architecture has not produced any
    # shard yet, leave the currently running legacy config/styles untouched.
    shopt -s nullglob
    local generated_shards=("$TILES_DIR"/*.mbtiles)
    shopt -u nullglob

    if [ "${#generated_shards[@]}" -eq 0 ]; then
        warn "No generated shard MBTiles exist yet."
        warn "Existing TileServer configuration was left untouched for safe migration."

        section "Done"
        warn "Fetch source maps, then run rebuild/sync to switch to the sharded architecture."
        return 0
    fi

    generate_runtime_styles
    generate_tileserver_config
    verify_runtime_styles_offline
    ensure_tileserver_running

    section "Done"

    if [ "$CONVERSION_FAILED" = true ]; then
        warn "TileServer is running, but at least one shard build failed."
        warn "Existing production MBTiles for failed shards were preserved."
        return 1
    fi

    success "Map server is fully synchronized."
    success "Countries are consolidated into geographic shards."
    success "Runtime map assets are local/offline."
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat <<'HELP_EOF'

Offline Map Manager - Sharded World Architecture

Usage:

  ./map_manager.sh
  ./map_manager.sh sync
      Synchronize fonts, auxiliary data, changed shards, styles and TileServer.

  ./map_manager.sh download
  ./map_manager.sh download iran
      Download/update one Geofabrik source, then synchronize changed shards.

  ./map_manager.sh fetch
  ./map_manager.sh fetch iran
      Download/update one source without rebuilding. Useful for batching.

  ./map_manager.sh rebuild
  ./map_manager.sh rebuild asia
      Force rebuild all shards or one named shard.

  ./map_manager.sh remove iran
      Remove a managed map source, then synchronize.

  ./map_manager.sh import asia /path/to/custom.osm.pbf custom-id
      Import a manual PBF into a named shard, then synchronize.

  ./map_manager.sh list
      List stored map sources and generated shards.

  ./map_manager.sh style
      Open the interactive OpenMapTiles style installer.

  ./map_manager.sh style osm-bright
  ./map_manager.sh style install osm-bright
      Preview and install/update one supported OpenMapTiles style.

  ./map_manager.sh style list
      List supported style downloads and installed source styles.

  ./map_manager.sh style remove osm-bright
      Remove a style and its matching local sprites, then synchronize.

  ./map_manager.sh cleanup
  ./map_manager.sh cleanup --yes
      Safely remove obsolete legacy root-level map files.

  ./map_manager.sh fonts
      Check/download local PBF fonts only.

  ./map_manager.sh data
      Check/download Tilemaker coastline and Natural Earth data only.

  ./map_manager.sh help
      Show this help.

Map architecture:

  maps/sources/asia/iran.osm.pbf
  maps/sources/asia/iraq.osm.pbf
             |
             +--> maps/tiles/asia.mbtiles

Style architecture:

  maps/styles/osm-bright/style.json
             |
             +--> style.runtime.json --> all generated shard MBTiles

OpenMapTiles style previews:

  https://openmaptiles.org/#map-styles

Configuration is loaded from .env.

HELP_EOF
}

# ==============================================================================
# Main
# ==============================================================================

acquire_lock

COMMAND="${1:-sync}"

case "$COMMAND" in
    sync)
        sync_all
        ;;

    download)
        shift || true
        SEARCH_QUERY="$*"

        geofabrik_download_menu "$SEARCH_QUERY"

        if [ "$DOWNLOAD_COMPLETED" = true ]; then
            info "Starting shard synchronization: $DOWNLOADED_SHARD"
            sync_all
        fi
        ;;

    fetch)
        shift || true
        SEARCH_QUERY="$*"
        geofabrik_download_menu "$SEARCH_QUERY"

        if [ "$DOWNLOAD_COMPLETED" = true ]; then
            success "Source stored. Run './map_manager.sh sync' when ready to build."
        fi
        ;;

    rebuild)
        shift || true
        TARGET="${1:-all}"
        sync_all "$TARGET"
        ;;

    remove)
        shift || true
        REGION_ID="${1:-}"
        [ -n "$REGION_ID" ] || die "Usage: ./map_manager.sh remove <region-id>"
        remove_source "$REGION_ID"
        sync_all
        ;;

    import)
        shift || true
        SHARD="${1:-}"
        SOURCE_PATH="${2:-}"
        REGION_ID="${3:-}"
        [ -n "$SHARD" ] && [ -n "$SOURCE_PATH" ] && [ -n "$REGION_ID" ] \
            || die "Usage: ./map_manager.sh import <shard> <file.osm.pbf> <source-id>"
        import_source "$SHARD" "$SOURCE_PATH" "$REGION_ID"
        sync_all
        ;;

    list)
        list_sources
        ;;

    style|styles)
        shift || true
        STYLE_ACTION="${1:-}"

        case "$STYLE_ACTION" in
            list)
                list_styles
                ;;

            remove)
                shift || true
                STYLE_ID="${1:-}"
                [ -n "$STYLE_ID" ] \
                    || die "Usage: ./map_manager.sh style remove <style-id> [--yes]"

                if [ "${2:-}" = "--yes" ]; then
                    remove_style "$STYLE_ID" true
                else
                    remove_style "$STYLE_ID" false
                fi

                if [ "$STYLE_CHANGED" = true ]; then
                    sync_all
                fi
                ;;

            install|add)
                shift || true
                STYLE_ID="${1:-}"
                ASSUME_YES=false

                if [ "${2:-}" = "--yes" ]; then
                    ASSUME_YES=true
                fi

                style_install_menu "$STYLE_ID" "$ASSUME_YES"

                if [ "$STYLE_CHANGED" = true ]; then
                    sync_all
                fi
                ;;

            "")
                style_install_menu

                if [ "$STYLE_CHANGED" = true ]; then
                    sync_all
                fi
                ;;

            *)
                STYLE_ID="$STYLE_ACTION"
                ASSUME_YES=false

                if [ "${2:-}" = "--yes" ]; then
                    ASSUME_YES=true
                fi

                style_install_menu "$STYLE_ID" "$ASSUME_YES"

                if [ "$STYLE_CHANGED" = true ]; then
                    sync_all
                fi
                ;;
        esac
        ;;

    cleanup)
        shift || true
        if [ "${1:-}" = "--yes" ]; then
            cleanup_legacy_layout true
        else
            cleanup_legacy_layout false
        fi
        ;;

    fonts)
        ensure_fonts
        ;;

    data)
        ensure_tilemaker_data
        ;;

    help|-h|--help)
        show_help
        ;;

    *)
        error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac
