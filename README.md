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

If you're upgrading a previous Overpass instance to use the source code or container image from this fork, you can reuse your existing database files. Skip to the **Running Overpass** section below to start the processes with your existing data.

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

After you have downloaded a database clone or imported a planet file or extract, or if you have an existing database, Overpass is ready to run.

The default configuration assumes minutely replication. If you're using an hourly or daily replication source, start by setting environment the environment variables to adapt to those intervals. The suggested configurations are in the `etc/overpass.env` file.

If you built Overpass from the source code:

```bash
OVERPASS_BIN_DIR=                 # path to the bin directory in your Overpass installation
export OVERPASS_REPLICATE_ID=auto # use the replicate_id file from the database directory
export OVERPASS_DB_DIR=           # path to your Overpass database directory
export OVERPASS_DIFF_DIR=         # path to the directory that will be used to store diff files
export OVERPASS_DIFF_URL=         # URL of the replication source that matches the database
export OVERPASS_UPDATE_FREQUENCY= # update interval in seconds (should match replication source)
export OVERPASS_META_MODE=        # yes|no|attic - include meta data, base data only, or attic data (should match existing database or import)
export OVERPASS_AREAS=            # yes|no - create or skip derived area data
nohup "$OVERPASS_BIN_DIR/run_osm3s.sh" &
```

And if you built from the source code, you will need to run your own web server with the /api path mapped to the Overpass cgi-bin directory. See the various guides at the top of this README for information on how to set that up.

Or if you're using the container image, it comes preconfigured with nginx:

```bash
OVERPASS_DB_DIR=                  # path to your Overpass database directory
OVERPASS_DIFF_DIR=                # path to the directory that will be used to store diff files
export OVERPASS_REPLICATE_ID=auto # use the replicate_id file from the database directory
export OVERPASS_DIFF_URL=         # URL of the replication source that matches the database
export OVERPASS_UPDATE_FREQUENCY= # update interval in seconds (should match replication source)
export OVERPASS_META_MODE=        # yes|no|attic - include meta data, base data only, or attic data (should match existing database or import)
export OVERPASS_AREAS=            # yes|no - create or skip derived area data
docker run -d \
  -v "$OVERPASS_DB_DIR":/opt/overpass/db \
  -v "$OVERPASS_DIFF_DIR":/opt/overpass/diff \
  -e OVERPASS_REPLICATE_ID \
  -e OVERPASS_DIFF_URL \
  -e OVERPASS_UPDATE_FREQUENCY \
  -e OVERPASS_META_MODE \
  -e OVERPASS_AREAS \
  -p 80:8080 \
  overpass
```

Alternatively, you can set the container parameters as environment variables using a .env script or your preferred container orchestration environment. Mount the OVERPASS_DB_DIR and OVERPASS_DIFF_DIR directories to the predefined paths, keep the variables local and leave them unset in the container.

## Maintenance

### Monitoring Overpass

The output from run_osm3s.sh will give you the status of the Overpass executables. There are several executables to watch for:

* The base dispatcher (dispatcher --osm-base), which controls access to the base, meta, and attic database files
* The areas dispatcher (dispatcher --areas), which controls access to the area database files
* fetch_osc.sh, which downloads diff files from the replication source
* apply_osc_to_db.sh, which unzips the .osc files from the replication source and sends them to update_database
* update_database, which writes the changes from .osc files to the database (runs only during database updates)
* rules_loop.sh, which periodically invokes the query to regenerate area data (optional)
* osm3s_query, which uses a rules file in the database directory to regenerate area data (runs only during area updates)
* backup.sh, which periodically copies the database files to a backup directory (optional)

If any of the core executables stops running, run_osm3s.sh will attempt to cleanly shut down the rest of the system.

The safest way to shutdown Overpass is to send SIGTERM to run_osm3s.sh. On bare metal, that's `kill "$RUN_OSM3S_PID"`. With the container image, that's `docker stop`. In either case, the run_osm3s.sh script will attempt to stop the components without interrupting the `update_database` process.

**Use caution when shutting down Overpass.** There is no safe way to interrupt the process of writing to the database. Killing the `update_database` process while it is running will often result in a corrupted database that must be replaced by restoring the files from a backup, downloading a new clone, or importing a new extract or planet file.

### Directory Structure

The Overpass directory structure includes several directories that are populated during the build process, and additional optional or conventional directories.

| Directory | Description | Notes |
| -- | -- | -- |
| `backup` | Contains the backup of the database; this should be mapped to a separate storage device on the host system | (Container Only) |
| `bin` | Contains the main Overpass executables and scripts | |
| `cgi-bin` | Contains executables for the CGI interface with the web server | |
| `db` | Contains the database files | (Conventional) |
| `diff` | Contains the diff files | (Conventional) |
| `include` | Contains C++ header files for integration with Overpass executables | |
| `log` | Contains the nginx web server log files | (Container Only) |
| `rules` | Contains the default rules files for area creation | (Container Only) |
| `run` | Contains runtime PID and lock files | (Container Only) |
| `templates` | Contains templates for wiki pages | |
| `test-bin` | Contains executables for testing the Overpass implementation | |
| `tmp` | (Container Only) Contains temporary files used by nginx | |

If you're building an running Overpass directly from source, most of the non-container directories could be wherever you've installed Overpass. However, the backup directory should be on a separate storage device. The "conventional" directories are typically placed in the same Overpass directory, but can be renamed or moved elsewhere with parameter changes.

Inside the container, all these directories reside under `/opt/overpass`. The only directories that *must* be mounted from the host are `db` and `backup`, because the data in these directories should be retained. Mounting any of the other data directories from the host is *optional*. You could mount `/opt/overpass/diff` if you'd like easier access to the diff files or the `fetch_osc.log` file. And you could mount `/opt/overpass/log` to get easier access to the nginx logs. But there is little reason to mount `run` or `tmp` directories since this information is not meaningful outside of the container.

### Log Files

Each of the executables produces log files and/or output files that have status information and may have an explanation if a component has failed:

| Executable | Log File | Output File |
| -- | -- | -- |
| dispatcher --osm-base | db/database.log | db/base-dispatcher.out |
| dispatcher --areas | db/database.log | db/areas-dispatcher.out |
| fetch_osc.sh | diff/fetch_osc.log | diff/fetch_osc.out |
| apply_osc_to_db.sh | db/apply_osc_to_db.log | db/apply_osc_to_db.out |
| update_database | db/database.log | db/apply_osc_to_db.out |
| rules_loop.sh | db/rules_loop.log | db/rules_loop.out |
| osm3s_query | db/transactions.log | db/rules_loop.out |
| backup.sh | db/backup.log | db/backup.out |

You can also tail these files to confirm the health of the Overpass system. A healthy Overpass instance will have periodic updates in the `fetch_osc.log` and `apply_osc_to_db.log` files. And the results of the latest area generation and backup will be in the `rules_loop.log` and `backup.log` files.

The run_osm3s.sh script includes automatic log and output file rotation to ensure that the files don't fill the file system.

### Database Backups

Overpass database backups are optional but *strongly* recommended. Even under the best circumstances, the Overpass database can eventually become corrupted. When this happens, the easiest and fastest way to recover is to restore the database files from a recent backup.

To enable automatic backups if you compiled from source code, set the following environment variables:

```bash
export OVERPASS_BACKUP_DIR=  # Target directory for backup files
export OVERPASS_BACKUP_TIME= # Time of day to run backup (00:00-23:59)
                             # Backup runs every day if OVERPASS_BACKUP_DAY is not set
export OVERPASS_BACKUP_DAY=  # Day to run backup: MON|TUE|WED|THU|FRI|SAT|SUN or 1-31
                             # Backup runs at 00:00 if OVERPASS_BACKUP_TIME is not set
```

If you're using the container, mount the backup directory to `/opt/overpass/backup` and keep OVERPASS_BACKUP_DIR local.

```bash
OVERPASS_BACKUP_DIR=  # Target directory for backup files
# docker run ....
  -v "$OVERPASS_BACKUP_DIR":/opt/overpass/backup
  #...
```

The backup script will pause database updates while the files are being copied.

Alternatively, you may run the `backup.sh` script manually or in a cron job.

### Optional Settings

All of the parameters for Overpass can be set using environment variables. See the `etc/overpass.env` template or the usage for individual scripts for additional documentation.
