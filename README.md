# Map Server (TileServer GL)

Self-hosted and offline map server based on **TileServer GL**, **Tilemaker**, and OpenStreetMap data.

Countries are stored as durable source PBF files and consolidated into geographic shards such as `asia.mbtiles` and `europe.mbtiles`. Styles, sprites, fonts, and generated map data are served locally during normal operation.

---

## Architecture

```text
Geofabrik
    │
    ├── Iran PBF ──┐
    ├── Iraq PBF ──┼──> maps/tiles/asia.mbtiles
    └── Japan PBF ─┘
                         │
    ├── Finland PBF ─┐  │
    └── Germany PBF ─┼──> maps/tiles/europe.mbtiles
                         │
                         ▼
                 runtime styles
                         │
                         ▼
                    TileServer GL
```

Adding or updating a country rebuilds only its geographic shard. Existing production MBTiles remain active until the replacement shard has been built and validated successfully.

Avoid overlapping Geofabrik extracts such as `france` + `alsace` or `asia` + `iran`. Prefer country-level extracts when building coverage incrementally.

---

## Project Structure

```text
map-server/
├── .env.example
├── .gitignore
├── docker-compose.yml
├── map_manager.sh
├── README.md
│
├── custom-ui/
│
├── maps/
│   ├── config.json                     # Auto-generated
│   ├── sources/                        # Durable source PBFs
│   │   ├── asia/
│   │   └── europe/
│   ├── tiles/                          # Generated shard MBTiles
│   │   ├── asia.mbtiles
│   │   └── europe.mbtiles
│   ├── styles/
│   │   └── [style-name]/
│   │       ├── style.json              # Source/template
│   │       └── style.runtime.json      # Auto-generated
│   ├── sprites/
│   │   └── [style-name]/
│   └── fonts/
│
└── tilemaker-config/
    ├── config-openmaptiles.json
    ├── process-openmaptiles.lua
    ├── coastline/                      # Auto-downloaded
    └── landcover/                      # Auto-downloaded
```

Large/generated map data, fonts, auxiliary datasets, runtime styles, and temporary files are excluded from Git.

---

## First Setup

Install the required command-line tools if needed:

```bash
sudo apt update
sudo apt install -y curl unzip python3 util-linux coreutils
```

Clone the project and create the local environment:

```bash
git clone <repository-url>
cd map-server

cp .env.example .env
nano .env

chmod +x map_manager.sh
```

Choose a map style:

```bash
./map_manager.sh style
```

Then download the first map region:

```bash
./map_manager.sh download iran
```

The manager automatically checks/downloads fonts and Tilemaker auxiliary datasets, builds the required shard, creates offline runtime styles and `maps/config.json`, and starts TileServer.

Multi-country shard builds require **Tilemaker 3.1.0 or newer**.

---

## Configuration

Important `.env` variables:

```dotenv
MAP_DOMAIN=

TILESERVER_IMAGE=
TILEMAKER_IMAGE=
TILEMAKER_EXTRA_ARGS=

FONTS_BUNDLE_URL=
GEOFABRIK_INDEX_URL=

COASTLINE_URL=
NATURAL_EARTH_URBAN_URL=
NATURAL_EARTH_ICE_SHELF_URL=
NATURAL_EARTH_GLACIER_URL=
```

Private registry addresses and deployment-specific values belong only in `.env`. The real `.env` file is not committed to Git.

---

## How to Add a New Map Region

Browse available OpenStreetMap extracts at:

```text
https://download.geofabrik.de/
```

For an interactive search:

```bash
./map_manager.sh download
```

Or search directly:

```bash
./map_manager.sh download iran
./map_manager.sh download finland
```

The script:

1. Searches the official Geofabrik index.
2. Shows the matching region and geographic shard.
3. Downloads the `.osm.pbf` with resume support.
4. Verifies the Geofabrik MD5 checksum when available.
5. Keeps the source PBF under `maps/sources/[shard]/`.
6. Rebuilds only the affected geographic shard.
7. Regenerates runtime styles/config and updates TileServer.

For several countries in the same shard, download first and build once:

```bash
./map_manager.sh fetch iran
./map_manager.sh fetch iraq
./map_manager.sh fetch japan

./map_manager.sh sync
```

This is preferred as coverage grows.

List managed maps:

```bash
./map_manager.sh list
```

---

## How to Add a New Map Style (Theme)

Browse and preview the official OpenMapTiles styles first:

```text
https://openmaptiles.org/#map-styles
```

Then open the interactive installer:

```bash
./map_manager.sh style
```

The installer shows preview links before installation and currently supports these ready-to-download OpenMapTiles styles:

```text
osm-bright
positron
dark-matter
fiord-color
maptiler-basic
```

You can also install one directly:

```bash
./map_manager.sh style osm-bright
```

or:

```bash
./map_manager.sh style install positron
```

The script downloads and validates the upstream `style.json` and sprite bundle, then stores them under:

```text
maps/styles/[style-name]/style.json

maps/sprites/[style-name]/
├── sprite.png
├── sprite.json
├── sprite@2x.png
└── sprite@2x.json
```

After installation, `style.runtime.json` is generated automatically. Remote map/font/sprite references are replaced by local shard, font, and sprite resources before TileServer uses the style.

List available/installed styles:

```bash
./map_manager.sh style list
```

Custom styles can still be added manually by placing their source `style.json` and matching sprites in the same directory structure and running:

```bash
./map_manager.sh sync
```

---

## How to Delete a Map or Style

Remove a managed map source:

```bash
./map_manager.sh remove iran
```

The affected shard is rebuilt automatically. If the removed country was the final source in that shard, the generated shard is removed during synchronization.

Remove a style and its matching sprites:

```bash
./map_manager.sh style remove osm-bright
```

Both commands update the generated configuration and TileServer automatically.

---

## Manual Map Import

If you already have a local `.osm.pbf`, import it into a shard:

```bash
./map_manager.sh import asia /path/to/custom.osm.pbf custom-id
```

Manual imports are not checked against the Geofabrik hierarchy, so avoid overlapping extracts.

---

## Fonts and Tilemaker Data

Local PBF glyphs are stored under:

```text
maps/fonts/
```

Check/install fonts only:

```bash
./map_manager.sh fonts
```

Tilemaker coastline and Natural Earth datasets are stored under:

```text
tilemaker-config/coastline/
tilemaker-config/landcover/
```

Check/install them only:

```bash
./map_manager.sh data
```

These datasets provide coastline/ocean and additional landcover information used by the OpenMapTiles processing configuration.

---

## Safe Builds

Each shard is built into a temporary file first:

```text
maps/tiles/.asia.building.mbtiles
```

Only after Tilemaker succeeds and the MBTiles file passes validation is it moved to:

```text
maps/tiles/asia.mbtiles
```

If a build fails, the existing production shard remains untouched and source PBFs are preserved.

Force one shard rebuild:

```bash
./map_manager.sh rebuild asia
```

Force all shards:

```bash
./map_manager.sh rebuild
```

---

## Legacy Migration Cleanup

After migrating an older installation and verifying the new sharded map works:

```bash
./map_manager.sh cleanup
```

The command removes only obsolete root-level map files after confirming that TileServer is using `maps/tiles/`.

---

## Useful Commands

```bash
./map_manager.sh sync

./map_manager.sh download
./map_manager.sh download iran

./map_manager.sh fetch iran
./map_manager.sh list
./map_manager.sh remove iran

./map_manager.sh rebuild asia
./map_manager.sh rebuild

./map_manager.sh style
./map_manager.sh style list
./map_manager.sh style osm-bright
./map_manager.sh style remove osm-bright

./map_manager.sh import asia /path/to/custom.osm.pbf custom-id

./map_manager.sh fonts
./map_manager.sh data
./map_manager.sh cleanup
./map_manager.sh help

docker compose ps
docker compose logs -f
```

---

## Offline Runtime

During normal map serving:

```text
Browser / Application
        │
        ▼
   TileServer GL
        │
        ├── maps/tiles/*.mbtiles
        ├── maps/styles/*/style.runtime.json
        ├── maps/sprites/
        └── maps/fonts/
```

Internet access is only needed when downloading/updating source maps, styles, fonts, auxiliary datasets, or Docker images.

---

## Accessing the Server

```text
https://maps.example.com

https://maps.example.com/styles/[style-name]/

https://maps.example.com/styles/[style-name]/style.json

https://maps.example.com/styles/[style-name]/512/{z}/{x}/{y}.png

https://maps.example.com/data/[shard-id]/{z}/{x}/{y}.pbf
```

---

## Git / Runtime Data

Git contains the scripts, Docker configuration, source styles/sprites, and Tilemaker configuration.

Runtime/generated data is not committed:

```text
.env

maps/config.json
maps/sources/
maps/tiles/
maps/fonts/
maps/temp_store/
maps/.downloads/
maps/.state/

maps/styles/*/style.runtime.json

tilemaker-config/coastline/
tilemaker-config/landcover/
```

For large shards, keep Tilemaker temporary storage on fast SSD storage and use:

```dotenv
TILEMAKER_EXTRA_ARGS=--shard-stores
```

Batch multiple country downloads with `fetch` before `sync` to avoid rebuilding a large shard after every individual download.
