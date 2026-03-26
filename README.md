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

Importing a planet file gives you complete control over the Overpass database and ensures that it starts from a clean data set. The full planet file is very large. Check the current `planet-latest.osm.bz2` file size on [planet.openstreetmap.org](https://planet.openstreetmap.org/planet/) and make sure you have plenty of disk space for *both* the planet file and the Overpass database files. Downloading and importing a full planet file can take a couple of days. Make sure your system can run this task in the background.

The import_osm_data.sh script takes care of downloading the planet file, verifying the MD5 checksum, importing the data, and setting the initial `replicate_id` file based on a chosen replication source. The script supports both HTTP and BitTorrent downloads (if you have aria2c installed), and will import either .osm.bz2 or .pbf files (if you have osmium installed).

If you built Overpass directly from the source code:

```bash
PLANET_FILE_URL=    # URL of the planet file to import
OVERPASS_DIFF_URL=  # URL of the chosen replication source associated with the planet file
OVERPASS_BIN_DIR=   # path to the bin directory in your Overpass installation
OVERPASS_DB_DIR=    # path to your Overpass database directory
OVERPASS_DIFF_DIR=  # path to the directory that will be used to store diff files
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
nohup "$OVERPASS_BIN_DIR/import_osm_data.sh" \
  --db-dir="$OVERPASS_DB_DIR" \
  --diff-dir="$OVERPASS_DIFF_DIR" \
  --diff-url="$OVERPASS_DIFF_URL" \
  --data-source="$PLANET_FILE_URL" \
  --meta="$OVERPASS_META_MODE" &
```

The container image already has aria2c and osmium built in.

```bash
PLANET_FILE_URL=    # URL of the planet file to import
OVERPASS_DIFF_URL=  # URL of the chosen replication source associated with the planet file
OVERPASS_DB_DIR=    # path to your Overpass database directory
OVERPASS_DIFF_DIR=  # path to the directory that will be used to store diff files
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
docker run -d --rm \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  -v "$OVERPASS_DIFF_DIR":/opt/overpass/diff \
  --entrypoint /opt/overpass/bin/import_osm_data.sh \
  overpass \
  --db-dir=/opt/overpass/db \
  --diff-dir=/opt/overpass/diff \
  --diff-url="$OVERPASS_DIFF_URL" \
  --data-source="$PLANET_FILE_URL" \
  --meta="$OVERPASS_META_MODE"
```

#### Initialize the Database from an Extract

Importing an extract allows you to work with a slice of the global data set, which uses fewer resources and can make query responses faster. There are several [sources for extracts](https://wiki.openstreetmap.org/wiki/Planet.osm#Extracts) which vary in the regions they cover, the frequency of updates, the availability of diff files (critical for Overpass), and the metadata that is included.

Once you've chosen an extract with diff files, initializing the database is similar to the full planet download but with a smaller file.

If you built Overpass directly from source code:

```bash
EXTRACT_FILE_URL=   # URL of the extract file to import
OVERPASS_DIFF_URL=  # URL of the chosen replication source associated with the extract file
OVERPASS_BIN_DIR=   # path to the bin directory in your Overpass installation
OVERPASS_DB_DIR=    # path to your Overpass database directory
OVERPASS_DIFF_DIR=  # path to the directory that will be used to store diff files
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
nohup "$OVERPASS_BIN_DIR/import_osm_data.sh" \
  --db-dir="$OVERPASS_DB_DIR" \
  --diff-dir="$OVERPASS_DIFF_DIR" \
  --diff-url="$OVERPASS_DIFF_URL" \
  --data-source="$EXTRACT_FILE_URL" \
  --meta="$OVERPASS_META_MODE" &
```

Or if you're using the container image:

```bash
EXTRACT_FILE_URL=   # URL of the extract file to import
OVERPASS_DIFF_URL=  # URL of the chosen replication source associated with the extract file
OVERPASS_DB_DIR=    # path to your Overpass database directory
OVERPASS_DIFF_DIR=  # path to the directory that will be used to store diff files
OVERPASS_META_MODE= # yes|no|attic - include meta data, base data only, or attic data
docker run -d --rm \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  -v "$OVERPASS_DIFF_DIR":/opt/overpass/diff \
  --entrypoint /opt/overpass/bin/import_osm_data.sh \
  overpass \
  --db-dir=/opt/overpass/db \
  --diff-dir=/opt/overpass/diff \
  --diff-url="$OVERPASS_DIFF_URL" \
  --data-source="$EXTRACT_FILE_URL" \
  --meta="$OVERPASS_META_MODE"
```

## Running Overpass

## Maintenance
