# Overpass-API

This project is a fork of drolbr/Overpass-API which is an API to perform queries and analytical processing on OpenStreetMap data.

* Upstream: [drolbr/Overpass-API](https://github.com/drolbr/Overpass-API)
* [Overpass API Wiki](https://wiki.openstreetmap.org/wiki/Overpass_API)
* [Overpass API Documentation](https://dev.overpass-api.de/)
* [Overpass Releases](https://dev.overpass-api.de/releases/?C=M;O=D)

Improvements in this fork:

* More resilient replication downloads using `fetch_osc.sh` or `fetch_osc_and_apply.sh`
* Safer recovery from uncontrolled shutdowns in `fetch_osc.sh`, `fetch_osc_and_apply.sh`, and `apply_osc_to_db.sh`
* Safer controlled shutdown in `apply_osc_to_db.sh` to reduce the risk of database corruption
* Faster downloads in `fetch_osc.sh`, `fetch_osc_and_apply.sh`, and `download_clone.sh`
* Support and optimization for hourly and daily replication sources in `fetch_osc.sh`, `fetch_osc_and_apply.sh`, and `apply_osc_to_db.sh`
* Adaptive and customizable area creation scheduling in `rules_loop.sh`
* NEW: Backup script that does not require the server to shut down in `backup.sh` and an associated `restore.sh` for recovery
* NEW: Automated cleanup of old diff data in `clean_osc.sh`
* NEW: Consolidated startup/entrypoint script in `run_osm3s.sh`
  * Supports minutely/hourly/daily replication
  * Supports attic/meta/basic data sets
  * Supports scheduled area creation
  * Automatically rotates log and output files
  * Automatically remotes old diff data
  * Automatically runs periodic backups
  * Performs periodic health checks on processes
  * Runs on bare metal or as a container entrypoint
* NEW: Support for container image builds
  * Minimal base image using debian:bookworm-slim
  * External mounts for database, replication, and backup data
  * Control all runtime parameters using environment variables

## Overview

This fork improves the project shell scripts to improve performance, resilience, and flexibility. It also adds support for Docker so that the project can be built as a container image.

There are several useful branches in this repo:

* `master`: Tracks the latest release in the upstream drolbr/Overpass-API repo
* `drolbr/v0.*`: Track the latest revision/hotfix from [dev.overpass-api.de](https://dev.overpass-api.de/releases/) (not available in the upstream repo)
* `b1tw153/improve-shell-scripts`: Feature branch with improved scripts
* `b1tw153/docker`: Feature branch with Docker assets (based on improve-shell-scripts)

If you plan to run Overpass directly in the OS, use the `b1tw153/improve-shell-scripts` branch. If you plan to build a container image, use the `b1tw153/docker` branch.

If you prefer to build Overpass from the original source, use either the [tarballs from the Overpass release web site](https://dev.overpass-api.de/releases/?C=M;O=D) or the `drolbr/v0.*` branches in this fork.

## Prerequisites / Requirements

See the [basic system requirements](https://wiki.openstreetmap.org/wiki/Overpass_API/Installation#System_Requirements) in the Overpass Wiki page.

The container build in this fork includes all of the necessary software. A container management or orchestration system such as Docker Compose or Kubernetes is recommended.

## Installation

### Building Overpass from Source

If you plan to build the Overpass components directly from the source code, there are instructions and guides from several sources:

* [Overpass API Wiki](https://wiki.openstreetmap.org/wiki/Overpass_API/Installation)
* [Overpass API Quick Installation Guide](https://dev.overpass-api.de/no_frills.html)
* [Overpass API Complete Installation Guide](https://dev.overpass-api.de/full_installation.html)
* [ZeLonewolf/Overpass Installation Guide](https://wiki.openstreetmap.org/wiki/User:ZeLonewolf/Overpass_Installation_Guide)
* [How to Build a Personal Overpass Server on a Tiny Budget](https://www.openstreetmap.org/user/Kai%20Johnson/diary/401263)
* [Setting up an Overpass API server - how hard can it be?](https://www.openstreetmap.org/user/SomeoneElse/diary/408252)

### Building the Container Image

Start with the `b1tw153/docker` branch. In the repo directory, run:

```bash
docker build -t overpass .
```

The build process will compile the source code. This may take 10-20 minutes.

### Initializing the Database

The Overpass API requires a set of database files to run. There are several options to obtain an initial set of database files.

If you're using the container image with bind-mounted host directories, create them and set ownership before running any container commands that write to them. The container runs as uid/gid 10001.

```bash
OVERPASS_DB_DIR=      # path to your Overpass database directory on the host
OVERPASS_DIFF_DIR=    # path to your Overpass diff directory on the host
OVERPASS_BACKUP_DIR=  # path to your Overpass backup directory on the host (optional)

mkdir -p "$OVERPASS_DB_DIR" "$OVERPASS_DIFF_DIR" "$OVERPASS_BACKUP_DIR"
chown -R 10001:10001 "$OVERPASS_DB_DIR" "$OVERPASS_DIFF_DIR" "$OVERPASS_BACKUP_DIR"
```

#### Use an Existing Database

If you're upgrading a previous Overpass instance to use the source code or container image from this fork, you can reuse your existing database files.

#### Initialize the Database from a Clone

Roland Olbricht maintains a daily clone of the full planet data for OpenStreetMap using minutely replication. If you built Overpass directly from source, download the clone using:

```bash
OVERPASS_BIN_DIR=   # path to the bin directory in your Overpass installation
OVERPASS_DB_DIR=    # path to your Overpass database directory
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
nohup "$OVERPASS_BIN_DIR/download_clone.sh" \
  --source=http://dev.overpass-api.de/api_drolbr/ \
  --db-dir="$OVERPASS_DB_DIR" \
  --meta="$OVERPASS_META_MODE" &
```

Or using the container image:

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint /opt/overpass/bin/download_clone.sh \
  overpass \
  --source="http://dev.overpass-api.de/api_drolbr/" \
  --db-dir="/opt/overpass/db" \
  --meta="$OVERPASS_META_MODE"
```

The database files are large and the download may take some time, so it's best to run it as a background process that will not terminate if the terminal connection is closed.

#### Initialize the Database from a Planet File

Importing a planet file gives you complete control over the Overpass database and ensures that it starts from a clean data set. The full planet file is very large. Check the current `planet-latest.osm.bz2` file size on [planet.openstreetmap.org](https://planet.openstreetmap.org/planet/) and make sure you have plenty of disk space for *both* the planet file and the Overpass database files.

If you built Overpass from the source code, you will need to use a separate tool to download the planet file. A torrent client such as aria2c is the best choice:

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
cd "$OVERPASS_DB_DIR"

# download .torrent and .md5 files
aria2c --seed-time=0 \
  https://planet.openstreetmap.org/planet/planet-latest.osm.bz2.md5 \
  https://planet.openstreetmap.org/planet/planet-latest.osm.bz2.torrent
```

You can download the files directly over HTTP, but this option is much slower than the torrent download. Check the current list of [Planet.osm mirrors](https://wiki.openstreetmap.org/wiki/Planet.osm#Planet.osm_mirrors) and choose an appropriate one for the download.

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
PLANET_OSM_MIRROR=  # URL to the planet directory on your chosen mirror
cd "$OVERPASS_DB_DIR"

# download .md5 file
curl -f -S -L -O \
  "$PLANET_OSM_MIRROR/planet-latest.osm.bz2.md5"

# download .bz2 file in the background without interrupts
nohup curl -f -S -L -C - -O \
  --retry 10 \
  --retry-delay 30 \
  --speed-limit 1024 \
  --speed-time 60 \
  "$PLANET_OSM_MIRROR/planet-latest.osm.bz2" &
```

If you're using the container image, it already has aria2c installed for torrent downloads.

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host

# download .md5 and .bz2 files in the background
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint aria2c \
  --workdir /opt/overpass/db \
  overpass \
  --seed-time 0 \
  https://planet.openstreetmap.org/planet/planet-latest.osm.bz2.md5 \
  https://planet.openstreetmap.org/planet/planet-latest.osm.bz2.torrent
```

Whichever download method you use, check the MD5 checksum after the download.

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
cd "$OVERPASS_DB_DIR"
md5sum -c planet-latest.osm.bz2.md5
```

... or ...

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
docker run --rm \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint md5sum \
  --workdir /opt/overpass/db \
  overpass \
  -c planet-latest.osm.bz2.md5
```

Now, initialize the Overpass database from the planet file.

```bash
OVERPASS_BIN_DIR=   # path to the bin directory in your Overpass installation
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
META_FLAG=          # --data-only|--meta|--keep-attic depending on which data you want to preserve
COMPRESSION_METHOD= # no|gz|lz4 (lz4 is recommended)
nohup bash <<EOF &
bunzip2 <"$OVERPASS_DB_DIR/planet-latest.osm.bz2" | \
"$OVERPASS_BIN_DIR/update_database" \
  --db-dir="$OVERPASS_DB_DIR" \
  $META_FLAG \
  --compression-method="$COMPRESSION_METHOD" \
  --map-compression-method="$COMPRESSION_METHOD"
EOF
```

Or, if you're using the container image:

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
META_FLAG=          # --data-only|--meta|--keep-attic depending on which data you want to preserve
COMPRESSION_METHOD= # no|gz|lz4 (lz4 is recommended)
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint bash \
  overpass \
  -c "$(cat <<EOF
bunzip2 </opt/overpass/db/planet-latest.osm.bz2 |
/opt/overpass/bin/update_database \
  --db-dir=/opt/overpass/db \
  $META_FLAG \
  --compression-method=$COMPRESSION_METHOD \
  --map-compression-method=$COMPRESSION_METHOD
EOF
)"
```

After importing the planet file, we need to find the correct `replicate_id` to use with the replication source. This is the sequence number of the last diff file that the planet file already includes. The first diff file to download will be the next one. Sequence numbers for `replicate_id` differ between replication sources, so you *must* use the replication source paired to the planet file. Use the `bisect_timestamp.sh` script to find the correct `replicate_id`.

Use the same mirror that you used to download the planet file for your replication source: [Planet.osm mirrors](https://wiki.openstreetmap.org/wiki/Planet.osm#Planet.osm_mirrors).

```bash
OVERPASS_BIN_DIR=       # path to the bin directory in your Overpass installation
OVERPASS_DIFF_DIR=      # path to the host directory that will be used to store diff files
OVERPASS_DIFF_SOURCE=   # URL to replication data from the same source as the planet file
export OVERPASS_DB_DIR= # path to your Overpass database directory on the host
                        # exporting this variable will allow bisect_timestamp.sh to
                        # read the osm_base_version file from the database directory
if OUTPUT=$("$OVERPASS_BIN_DIR/bisect_timestamp.sh" "$OVERPASS_DIFF_SOURCE" "$OVERPASS_DIFF_DIR"); then
  echo "REPLICATE_ID=$OUTPUT"
  echo "$OUTPUT" > "$OVERPASS_DB_DIR/replicate_id"
else
  echo "Unable to determine REPLICATE_ID:"
  echo "$OUTPUT"
fi
```

Or do the same using the container image:

```bash
OVERPASS_DIFF_DIR=    # path to the host directory that will be used to store diff files
OVERPASS_DB_DIR=      # path to your Overpass database directory on the host
OVERPASS_DIFF_SOURCE= # URL to replication data from the same source as the planet file
docker run --rm \
  -v "$OVERPASS_DIFF_DIR":/opt/overpass/diff \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint bash \
  overpass \
  -c "$(cat <<EOF
if OUTPUT=\$(/opt/overpass/bin/bisect_timestamp.sh "$OVERPASS_DIFF_SOURCE" /opt/overpass/diff); then
  echo "REPLICATE_ID=\$OUTPUT"
  echo "\$OUTPUT" > /opt/overpass/db/replicate_id
else
  echo "Unable to determine REPLICATE_ID:"
  echo "\$OUTPUT"
fi
EOF
)"
```

#### Initialize the Database from an Extract

Importing an extract allows you to work with a slice of the global data set, which uses fewer resources and can make query responses faster. There are several [sources for extracts](https://wiki.openstreetmap.org/wiki/Planet.osm#Extracts) which vary in the regions they cover, the frequency of updates, the availability of diff files (critical for Overpass), and the metadata that is included.

Once you've chosen an extract with diff files, initializing the database is similar to the full planet download but with a smaller file and typically with an additional format conversion step. Overpass requires input in OSM XML format, but most extracts are in PBF format. The extracts can be converted from PBF to OSM XML using osmium or a similar tool.

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
EXTRACT_FILE_URL=   # URL to your chosen extract file

cd "$OVERPASS_DB_DIR"

# download the .md5 and .pbf file in the background without interrupts
nohup curl -f -S -L -C - -O \
  --retry 10 \
  --retry-delay 30 \
  --speed-limit 1024 \
  --speed-time 60 \
  "$EXTRACT_FILE_URL.md5" \
  "$EXTRACT_FILE_URL" &
```

If you're using the container image, using aria2c for the download may be faster.

```bash
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint aria2c \
  --workdir /opt/overpass/db \
  overpass \
  -x 16 -s 16 \
  "$EXTRACT_FILE_URL.md5" \
  "$EXTRACT_FILE_URL"
```

If the extract file is in .osm.pbf format, it can be imported into the Overpass database using the same process as above for the planet file. Most extracts are .pbf files, which require a different conversion step. Keep in mind that many extracts have limited metadata and few extracts have the historical data required for Overpass attic data.

If you built Overpass directly from the source code, install osmium for the PBF to OSM XML conversion.

```bash
sudo apt-get install osmium-tool # or the equivalent for your system, if needed

OVERPASS_BIN_DIR=   # path to the bin directory in your Overpass installation
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
EXTRACT_FILE_NAME=  # name of the extract file you downloaded
META_FLAG=          # --data-only|--meta|--keep-attic depending on which data you want to preserve
COMPRESSION_METHOD= # no|gz|lz4 (lz4 is recommended)
nohup bash <<EOF &
osmium cat -f osm "$OVERPASS_DB_DIR/$EXTRACT_FILE_NAME" | \
"$OVERPASS_BIN_DIR/update_database" \
  --db-dir="$OVERPASS_DB_DIR" \
  $META_FLAG \
  --compression-method="$COMPRESSION_METHOD" \
  --map-compression-method="$COMPRESSION_METHOD"
EOF
```

If you're using the container image, it already has osmium installed.

```bash
OVERPASS_DB_DIR=    # path to your Overpass database directory on the host
EXTRACT_FILE_NAME=  # name of the extract file you downloaded
META_FLAG=          # --data-only|--meta|--keep-attic depending on which data you want to preserve
COMPRESSION_METHOD= # no|gz|lz4 (lz4 is recommended)
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint bash \
  overpass \
  -c "$(cat <<EOF
osmium cat -f osm "/opt/overpass/db/$EXTRACT_FILE_NAME" |
/opt/overpass/bin/update_database \
  --db-dir=/opt/overpass/db \
  $META_FLAG \
  --compression-method=$COMPRESSION_METHOD \
  --map-compression-method=$COMPRESSION_METHOD
EOF
)"
```

After importing the extract file, we need to find the correct `replicate_id` to use with the replication source. This is the sequence number of the last diff file that the extract file already includes. The first diff file to download will be the next one. Sequence numbers for `replicate_id` differ between replication sources, so you *must* use the replication source paired to the extract file. Use the `bisect_timestamp.sh` script to find the correct `replicate_id` for your chosen replication source.

```bash
OVERPASS_BIN_DIR=       # path to the bin directory in your Overpass installation
OVERPASS_DIFF_DIR=      # path to the host directory that will be used to store diff files
OVERPASS_DIFF_SOURCE=   # URL to replication data from the same source as the extract file
export OVERPASS_DB_DIR= # path to your Overpass database directory on the host
                        # exporting this variable will allow bisect_timestamp.sh to
                        # read the osm_base_version file from the database directory
if OUTPUT=$("$OVERPASS_BIN_DIR/bisect_timestamp.sh" "$OVERPASS_DIFF_SOURCE" "$OVERPASS_DIFF_DIR"); then
  echo "REPLICATE_ID=$OUTPUT"
  echo "$OUTPUT" > "$OVERPASS_DB_DIR/replicate_id"
else
  echo "Unable to determine REPLICATE_ID:"
  echo "$OUTPUT"
fi
```

Or do the same using the container image:

```bash
OVERPASS_DIFF_DIR=    # path to the host directory that will be used to store diff files
OVERPASS_DB_DIR=      # path to your Overpass database directory on the host
OVERPASS_DIFF_SOURCE= # URL to replication data from the same source as the extract file
docker run --rm \
  -v "$OVERPASS_DIFF_DIR":/opt/overpass/diff \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  --entrypoint bash \
  overpass \
  -c "$(cat <<EOF
if OUTPUT=\$(/opt/overpass/bin/bisect_timestamp.sh "$OVERPASS_DIFF_SOURCE" /opt/overpass/diff); then
  echo "REPLICATE_ID=\$OUTPUT"
  echo "\$OUTPUT" > /opt/overpass/db/replicate_id
else
  echo "Unable to determine REPLICATE_ID:"
  echo "\$OUTPUT"
fi
EOF
)"
```

## Running Overpass

## Maintenance
