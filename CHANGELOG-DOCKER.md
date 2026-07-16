=0.7.62.11-r15 (2026-07-16)=

* Hardened cgi-bin scripts and binaries (`augmented_diff`, `augmented_diff_status`, `augmented_state_by_date`, `convert`, `convert_xapi`, `draw-line`, `kill_my_queries`, `map`, `sketch-line`, `sketch-options`, `sketch-route`, `template`, `xapi`, `xapi_meta`): URL query string decoding correctness, parameter/input validation, path construction, and error handling
* Fixed URL query string parsing in the C++ frontend (`cgi-helper.cc/h`, `user_interface.cc`, `processed_input.cc`, `uncgi.cc`): off-by-one in percent-decode bounds check, delimiter search scoped to its segment, faster bounded chunked POST body read
* Rebuilt the bbox placeholder substitution to run in a single pass over the query string
* Rejected line breaks in the `[out:custom]` `url` parameter
* Removed the `/container-status` nginx endpoint and its cgi-bin script; `container_status.sh` is now run from the command line only
* Removed `osm_mem_status` from the default Munin plugin set; updated other Munin graph descriptions
* Guarded the `operates_*` opening-hours parse against values too short for its fixed-offset substrings
* Made `download_clone.sh` speed-limit stall detection more forgiving (`DOWNLOAD_CLONE_SPEED_LIMIT` default 1024→16 bytes/sec, `DOWNLOAD_CLONE_SPEED_TIME` default 30→60s)
* Added `pull: true` to the CI build step so the image always builds against the latest `debian:bookworm`/`debian:bookworm-slim` base images
* Corrected the documented default value for `NGINX_CONNECTION_QUEUE` in `overpass.env`
* Added `CHANGELOG-DOCKER.md` to track changes in container releases

=0.7.62.11-r14 (2026-07-08)=

* Integrated Munin monitoring into the container build: new plugins for cgroup CPU/memory/swap/pressure, container uptime, the dispatcher, the interpreter (including query time histograms and client rejection logging), and nginx (access, request queue, status); expanded `osm_db_lag` and `osm_mem_status`; added `etc/munin-node.conf.template`, `etc/munin-osm`, and `src/munin/README.md`
* Reworked concurrency controls (`FCGIWRAP_WORKERS`, `NGINX_CONNECTION_QUEUE`, client connection/rate limits) based on performance testing
* Added a startup parameter block to `entrypoint.sh`

=0.7.62.11-r13 (2026-06-25)=

* Added output redirection for the nginx and fcgiwrap processes
* Removed a redundant startup check from `apply_osc_to_db.sh` now that `run_osm3s.sh` covers it
* Changed `fetch_osc.sh` to start from the database state when using `auto`, to verify all diff files have been downloaded
* Added notes to README.md about area generation at first startup

=0.7.62.11-r12 (2026-06-21)=

* Improved per-query stats, process PID retrieval, and error handling in `container_status.sh`

=0.7.62.11-r11 (2026-06-19)=

* Added a `static` directory to the build with `robots.txt` and `llms.txt`, served via a new nginx location block
* Added structured error bodies for 429 and 504 responses and an `NGINX_CONNECTION_QUEUE` setting to control request queuing beyond worker capacity
* Added health check failure messages
* Fixed nginx status code parsing in `container_status.sh`

=0.7.62.11-r10 (2026-06-04)=

* Improved recovery from an uncontrolled shutdown in `run_osm3s.sh`
* Dropped the `base-url` argument from `restore.sh`

=0.7.62.11-r9 (2026-05-21)=

* Added `container_status.sh`, a new script reporting backup, replication, and process status (including a JSON output mode)
* Made `entrypoint.sh` enter zombie mode if a main process dies unexpectedly, avoiding Docker restart loops when the container needs attention
* Added free-space checks to `import_osm_data.sh`, `download_clone.sh`, and before applying updates, to prevent database corruption when the file system is nearly full
* Reordered the shutdown sequence and backup status reporting to reduce the likelihood of race conditions
* Added environment variable validation to `apply_osc_to_db.sh`
* Changed `run_osm3s.sh` to run `clean_osc.sh` at startup instead of waiting up to 24 hours for the first run
* Reformatted usage and startup banners

=0.7.62.11-r8 (2026-05-10)=

* Made `backup.sh` terminate its rsync process within the container shutdown grace period

=0.7.62.11-r7 (2026-04-25)=

* Added default container resource limits and nginx rate limiting; documented suggested resource allocations in README.md
* Renamed `etc/nginx.conf` to `etc/nginx.conf.template` and expanded its configuration

=0.7.62.11-r6 (2026-04-24)=

* Fixed a bug in how `apply_osc_to_db.sh` passed the `--timeout` argument to `inotifywait`

=0.7.62.11-r5 (2026-04-21)=

* Added a watchdog timer around `inotifywait` calls in `apply_osc_to_db.sh` to cover reliability issues with inotify on Docker bind mounts

=0.7.62.11-r4 (2026-04-20)=

* Removed obsolete `startup.sh`, `shutdown.sh`, and `single_pass_area_updater.sh` scripts, superseded by `entrypoint.sh` and `run_osm3s.sh`
* Rewrote README.md to serve as the Docker Hub image overview

=0.7.62.11-r3 (2026-04-19)=

Fixed the CI workflow's automatic push of README.md to the Docker Hub overview and bumped the Node.js runtime version used by that action.

=0.7.62.11-r1 (2026-04-19)=

Initial container release.

* Fixed argument parsing, `--osc-dir` validation, and a `flush_limit` overflow in `update_from_dir`/dispatcher
* Rewrote the replication scripts (`download_clone.sh`, `fetch_osc.sh`, `apply_osc_to_db.sh`) to use curl instead of wget, with input validation, retry/backoff logic, and consistent exit codes
* Added `entrypoint.sh`, `backup.sh`, PID/lock file handling, and hourly/daily support in `rules_loop.sh`
* Added README.md documentation, `import_osm_data.sh`, `bisect_timestamp.sh`, `restore.sh`, standardized environment variable names, and refined backoff timing in `fetch_osc.sh`
* Added the Dockerfile, nginx configuration, non-privileged container user, healthcheck, and rsync/logrotate/aria2/osmium support
* Added the GitHub Actions workflow to build and publish the image to Docker Hub
