# Munin Plugins for Overpass

Munin is a resource monitoring tool that collects time series data from systems and
graphs the data. A working Munin system has three parts: a Munin node with plugins to
collect resource statistics; a Munin master which polls the node, records data in RRD
files; and renders HTML pages and PNG graphs; and a separate web server that serves
the HTML pages and PNG graphs.

This directory contains the plugins for a Munin node to monitor Overpass and the
environment it runs in.

The container build in this project includes the Munin node software, disabled by
default. See below for instructions to enable Munin and review the data.

## Quick Start

### Run Munin node to collect data

The Munin node process listens on port 4949 and delivers resource statistics when it
is polled by the Munin master.

#### Container Build

1. Set the `MUNIN_NODE_CIDR_ALLOW` environment variable in the container to enable the
   Munin node process and allow connections from the Munin master. The format is an
   IPv4 CIDR block. Using `0.0.0.0/0` is fine in most cases because inbound
   connections are controlled through the Docker environment.
2. Set the `MUNIN_NODE_HOST_NAME` environment variable in the container to identify
   the Overpass host. Using the host name is fine. Or, if you only have one Overpass
   instance, using `overpass` works well too.
3. Map a host port to container port 4949. This exposes the Munin node endpoint so the
   Munin master can collect data from it.

#### Bare Metal

1. Install either Munin node or Munin master, which comes with its own Munin node.
   - If you intend to run Munin master on a separate system, install Munin node here,
     typically `sudo apt install munin-node` or similar.
   - If you will be running all the components on the same host, install Munin master
     and use its Munin node installation, typically `sudo apt install munin` or similar.
2. Copy Munin plugins and `osm_logtail.sh` from `src/munin` (this directory) into the
   `/usr/share/munin/plugins/` directory. (You might not want to copy this README.md
   file.)
3. Symlink the plugins you plan to use into the `/etc/munin/plugins/` directory.
   Munin comes with plugins that collect essentially the same data as the `cgroup_cpu`,
   `cgroup_memory`, and `cgroup_swap` plugins, so these plugins aren't necessary. But
   the `cgroup_pressure` plugin provides new information that is *very useful*. The
   `osm_mem_status` and `osm_timeout_status` plugins are legacy versions that have been
   replaced by the `osm_dispatcher` plugin -- you could skip those unless you want
   compatibility with previous Overpass tarballs. The `osm_nginx_queue` and
   `osm_nginx_status` plugins are obviously only useful with nginx.
4. Copy the `etc/munin-osm` file to `/etc/munin/plugin-conf.d/` and edit the file to
   fill in the necessary environment variables.
5. Restart the Munin node to allow it to read the new configuration and access the new
   plugins.

### Run Munin master to collate data

If you're using the container build or running on bare metal with the Munin master on a
separate system, you will need to install and configure the Munin master.

1. Install Munin master, typically `sudo apt install munin` or similar.
2. Edit `/etc/munin/munin.conf` to add the configuration to connect to the Munin node:

    ```conf
    [overpass;overpass]
        address <Munin node IP address>
        port 4949
        use_node_name yes
    ```

3. Restart the Munin master to reload the configuration.

Note that if you're running the container and the Munin master on the same system, the
Munin master will be running a Munin node listening on host port 4949. That gives you
the stats on the host environment. You'll need to map the container's Munin node to
another port (e.g., 4950) and use that port in the `munin.conf` file.

### Run a web server to serve Munin pages and graphs

The Munin master collects data and renders HTML and PNG graphs at regular intervals.
To see the HTML and PNG graphs in a web browser, you'll need a web server to serve up
the files.

The rendered HTML and PNG files are in `/var/cache/munin/www`. Use a web server like
nginx or Apache to serve them.

## Munin Plugins and Graphs

### cgroup_cpu

This plugin graphs user and system CPU usage from the container's perspective, which
provides a window into the container's internal CPU usage. It is best compared with
the default Munin `cpu` plugin for a broader view into the host CPU usage.

### cgroup_memory

This plugin collects memory statistics from the container's perspective.

#### Memory usage

This graph shows memory usage inside the container, which helps separate container memory
issues from the host memory view from Munin's default `memory` plugin.

Overpass queries typically cache hundreds of MB or even GB of data from the database. It
is normal for the memory graphs to be dominated by cache usage.

#### Memory working set thrashing

This graph shows file-cache refaults and major page faults, which indicate how Overpass
is using memory. File-cache refaults increase when there is pressure on I/O caching.
That typically indicates contention between Overpass queries for data from the database.

Increased major page faults indicate more serious memory issues. This happens when severe
memory pressure forces application page faults.

Swap usage is another view of memory pressure. Background, low-level swap usage is
normal. High, steady swap usage may indicate that `vm.swappiness` is set too high. Spikes
in swap usage suggest memory pressure events.

### cgroup_pressure

This plugin collects pressure stall information (PSI) when available to indicate when
processes are stalled and waiting for CPU, memory, or I/O. This is an excellent view of
the health of the system.

"Some" measures the percentage of time at least one task was stalled. This indicates
early resource contention. "Full" measures the percentage of time all non-idle tasks
were simultaneously stalled. This indicates a critical bottleneck. Under normal
conditions, pressure stalls should be minimal. A low level of some tasks stalled or
even full stalls is normal. Spikes or consistently elevated stalls indicate resource
contention or oversubscription.

#### CPU pressure

This graph shows tasks stalled and waiting for CPU scheduling. On a well-tuned system,
both "some" and "full" stalls will be minimal. If Overpass is handling more concurrent
queries than it has CPUs, "some" stalls will rise, indicating that queries are waiting
for CPU time. This is a normal trade-off between query latency and query rejection
(e.g., HTTP 429 responses).

Very high levels of CPU pressure indicate that the query load is more than the system
can handle. Consider rate limiting queries or taking other steps to reduce query load.

#### Memory pressure

This graph shows tasks stalled and waiting for free memory. Normal cache usage by
Overpass queries typically does not drive memory pressure. On a well-tuned system,
memory pressure should be minimal. However, at extreme levels, demand for cache by
queries can squeeze application memory. Consider rate limiting queries or taking
other steps to reduce query load if memory pressure rises above a minimal level.

#### I/O pressure

This graph shows tasks stalled and waiting for storage I/O. Overpass reads huge
amounts of data from the database as it processes queries, updates, and area
generation. Storage I/O performance is critical, but fast NVMe devices typically
provide enough throughput to serve Overpass.

On a well-tuned system, small spikes in I/O pressure up to 10% are normal. Higher
levels of I/O pressure indicate that database storage performance may not be
optimal.

### cgroup_swap

This graph shows swap activity from the container's perspective. On a well-tuned
Overpass system, swap activity should normally be minimal. However, area generation
may drive some transient increases in swap usage.

Consistently high levels of swap usage indicate significant memory constraints. Review
the memory usage and memory pressure graphs for other indications.

### container_uptime

This graph shows the container uptime, separate from the host uptime. If the container
is running and healthy, Overpass is able to serve queries.

### osm_db_lag

This graph shows the difference between the Overpass base and areas database
timestamps and real time. The graph will follow a sawtooth pattern based on the
replication frequency and area update frequency. Some of the variation in
replication lag will be due to latency at the replication source. A steadily
increasing value indicates that something is wrong with the database updates.

### osm_db_request_count

This graph shows Overpass query processing from the perspective of the `dispatcher`
process. The `dispatcher` tracks queries that have been received for processing,
so queries that are queued in the web server are not included in this graph. Neither
are queries that are pending or deferred in CGI processing or that time out before
reaching the `dispatcher`.

Compare this graph with the web server's access requests to identify requests that
may not have reached the `dispatcher`.

Each line on the graph represents a different population of queries:

- **started** represents queries that have been "accepted" for processing and that
  are able to run.
- **completed** represents queries that have finished processing and that have
  delivered results back through the CGI pipeline -- and to the client if the
  connection is still open.
- **shedded** represents queries that the `dispatcher` has rejected because its global
  resource pools for "space" and "time" are overcommitted. The status of these pools
  is visible in the "claimed memory" and "claimed time" graphs.
- **rate_limited** represents queries rejected because the client IP address has
  submitted more concurrent or frequent requests than the `--rate-limit` setting in
  the `dispatcher` allows.
- **duplicate** represents queries rejected because they were exact duplicates of
  previous queries (if `--allow-duplicate-queries=no`).

### osm_dispatcher

#### Dispatcher claimed memory

This graph shows the "space" claimed by queries in default or `[maxsize:]`
allocations from the `--space` pool in the `dispatcher`. There are separate pools for
the base and areas `dispatcher` processes.

The "space" pool acts as a global concurrency limit and ramps up per-client rate
limiting when allocations are high. When the allocated "space" nears the limit in the
`dispatcher` queries will be rejected as "shedded". With the default 512MB
`[maxsize:]` allocation and the default 12GB `--space` setting in the `dispatcher`,
the effective maximum is ~24 concurrent queries.

The container sets the `--space` allocation in the `dispatcher` to 768GB to disable
this concurrency limit. Instead, the container limits the number of fcgiwrap workers
to constrain concurrency.

#### Dispatcher claimed time units

This graph shows the "time" claimed by queries in default or `[timeout:]`
allocations from the `--time` pool in the `dispatcher`. There are separate pools for
the base and areas `dispatcher` processes.

The "time" pool acts as a global concurrency limit and ramps up per-client rate
limiting when allocations are high. When the allocated "time" nears the limit in the
`dispatcher` queries will be rejected as "shedded". The default 262144 second `--time`
setting in the `dispatcher` is high enough that this limit is effectively disabled.

### osm_interpreter

This plugin uses the `osm_logtail.sh` helper to scrape statistics from the
`transactions.log` file, which contains log records written by the Overpass client
processes.

#### Overpass interpreter run time

This graph shows total query run time and CPU time consumed by completed queries,
summed per minute -- the aggregate load on the interpreter. CPU time splits into
"query time" (evaluating the query's statements) and "collate time" (assembling the
`out` statement's results). Collate time is data materialization -- collecting tag and
meta data for each output element -- not text formatting. An `out meta` query can
spend many times more collate time (and more block reads, see below) than the same
query with `out ids`.

Run time is normally higher that CPU time because it tracks time when the query is not
executing. An increase in the ratio between run time and CPU time indicates an
increase in query latency where queries are spending time waiting rather than
executing. Although there are other possible causes, this can happen with CPU
contention or when queries are deferred by the dispatcher's concurrency limits.

#### Overpass interpreter run time per query

This graph shows the same run time and CPU time breakdown as an average per completed
query, rather than a per-minute total. It normalizes out changes in query volume, so
it's the graph to read for whether individual queries are getting slower or faster.

Rising "query" and "collate" time here indicate that queries are more complex and
demand more CPU time.

#### Overpass interpreter block reads

This graph shows the total number of database blocks read per minute, summed across
all completed queries -- the aggregate I/O load on the interpreter, independent of CPU
or run time. Each unit is one call into the database's block-read layer, whether or
not the block was served from the OS page cache, so the count reflects data accessed
rather than physical disk I/O. Database block sizes vary depending on the file type,
so this is *not* a direct view of I/O throughput.

#### Overpass interpreter block reads per query

This graph shows the same block reads count as an average per completed query, rather
than a per-minute total. Like the run time per query graph, it factors out changes in
query volume, so it's the graph to read for whether individual queries are reading
more or less data, as opposed to whether more queries are running.

#### Overpass interpreter CPU-time histogram (query counts)

#### Overpass interpreter CPU-time histogram (CPU-seconds)

#### Overpass interpreter client-side rejections

### osm_interpreter_procs

#### Overpass interpreter query age

#### Overpass interpreter query memory

### osm_mem_status

### osm_nginx_access

#### nginx HTTP response codes

#### nginx egress bytes

#### nginx average response size

#### Overpass nginx requests by endpoint

#### nginx response latency

#### Overpass nginx distinct API clients

#### Overpass nginx API client concentration

### osm_nginx_queue

### osm_nginx_status

#### nginx connections

#### nginx connection rate

### osm_timeout_status
