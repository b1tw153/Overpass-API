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

#### CPU usage

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

#### Swap usage

This graph shows swap activity from the container's perspective. On a well-tuned
Overpass system, swap activity should normally be minimal. However, area generation
may drive some transient increases in swap usage.

Consistently high levels of swap usage indicate significant memory constraints. Review
the memory usage and memory pressure graphs for other indications.

### container_uptime

#### Uptime

This graph shows the container uptime, separate from the host uptime. If the container
is running and healthy, Overpass is able to serve queries.

### osm_db_lag

#### Local database age

This graph shows the difference between the Overpass base and areas database
timestamps and real time. The graph will follow a sawtooth pattern based on the
replication frequency and area update frequency. Some of the variation in
replication lag will be due to latency at the replication source. A steadily
increasing value indicates that something is wrong with the database updates.

### osm_db_request_count

#### Overpass API request count

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

This graph buckets completed queries by the CPU time each one consumed, counting how
many fall into each band per minute. Queries rejected before running do not appear
here. The graph shows CPU time, not run time, so it does not show latency while
queries are not executing.

A vertical slice of the graph is the CPU-time distribution of queries that recently
finished. The bands in the graph show how many queries used CPU time within each of
the buckets.

Read this graph together with its CPU-seconds twin below. The count histogram shows how
many queries fall in each cost class; the twin shows how much CPU each class consumes.
On its own the count histogram cannot tell you where CPU time actually goes, because a
band packed with cheap queries and a band holding a few expensive ones can look alike
here. The pair resolves that.

Watch how the shape moves over weeks and months. Mass shifting from lower bands into
higher ones means individual queries are getting more expensive -- each query is
crossing into a higher CPU bucket. A band simply growing taller means more queries
landed in that same cost class, with no change in what a query costs.

#### Overpass interpreter CPU-time histogram (CPU-seconds)

This graph uses the same nine CPU-time buckets as the query-count histogram, but instead
of counting queries it sums the CPU seconds the queries in each band consumed, per
minute. Band height is the bucket's share of CPU time, so the graph shows which
buckets of queries use more CPU. The total height across all bands
matches the aggregate "CPU time" line on the "Overpass interpreter run time" graph.

The pairing with the count histogram is what makes either graph useful:

- A high band that holds few queries in the count histogram but a large share of CPU
  seconds in the CPU-seconds histogram is a tail of individually expensive queries --
  few in number, heavy in cost.
- When both histograms keep their shape and scale up together, the query mix is
  unchanged and only the query volume has risen.
- A shift toward more CPU per query looks different. Mass moves out of the lower bands
  and into the higher ones in both histograms, rather than every band growing in place.

#### Overpass interpreter client-side rejections

This graph counts queries that were rejected before they ran, per minute, by reason.
The counts come from the `interpreter` side of its negotiation with the `dispatcher`.
Two of the four reasons (rate limited, duplicate query) match the corresponding
reasons reported by the `dispatcher`. However, **"defer timeout"** events are not
reported anywhere else. And **"hash blacklisted"** events are only visible as a gap
between "started" and "completed" queries.

When a query process asks the `dispatcher` for database access, the `dispatcher` does
one of three things: admit it, reject it, or *defer* it. The `dispatcher` counts
admissions and rejections as "started", "shedded", or "rate_limited". But a deferral
is a pending state. The `dispatcher` briefly declines to admit the query while a
client rate limit or global resource limit is tripped. The query process keeps
retrying.

A "defer timeout" happens when the query process's own timer runs out before the
`dispatcher` admits or rejects it. Because it was never admitted or rejected, none of
the `dispatcher` counters are incremented. And because it never ran, it is absent from
the interpreter run time and histogram graphs as well. A query lost this way is
invisible everywhere except here.

A rising "defer timeout" count means queries are being deferred long enough that
`interpreter` processes give up waiting for admission -- sustained admission pressure
that the `dispatcher` counters do not show.

A blacklist of query hashes can be placed in a file in the database directory. After a
query is admitted, the `interpreter` hashes the query content, checks it against the
blacklist, and terminates the query if there is a match.

Because the query was admitted, it shows up in "started" count reported by the
`dispatcher`. But because it was terminated before it ran, it does not show up in the
"completed" count. This graph shows the queries that were "hash blacklisted" directly.

Read this graph alongside "Overpass API request count" to compare counted and
uncounted rejections.

### osm_interpreter_procs

This plugin takes a point-in-time sample of the `interpreter` processes. It is the
in-flight complement to the `osm_interpreter` graphs which only track queries after
they complete. A query that runs for minutes or hours does not appear in those graphs
until it finishes, but this plugin samples it on every tick. Conversely, queries with
short run times pass between ticks unsampled, so these graphs are dominated by
long-running queries.

Both graphs pair an "all running queries" total with an "oldest" or "biggest" single
query. The ratio between the two lines shows how concentrated the resource demand is.
The lines touching means a single query is generating all the resource demand. The
broader the gap between the lines, the more demand is spread across the pool of
running queries.

#### Overpass interpreter query age

This graph shows the age of the longest running query alongside the summed age of all
running queries. When the two lines touch, one query has been running for much longer
than all the others. When the total pulls well above the oldest line, many queries
have been running for roughly the same time. If there's a large gap between the total
and oldest and the total is relatively high, there are more long-running queries. And if
the total is low, all the queries are completing quickly.

Note that a wide gap may reflect many concurrent queries -- compare with the executing
count on the "Overpass query pipeline" graph to distinguish between a small set of
long-running queries and a large set of shorter queries.

#### Overpass interpreter query memory

This graph shows the largest resident set among running queries alongside their
summed resident set. If the biggest query line is close to the total, a single query
has allocated a large amount of memory. If the total is well above the biggest line,
memory allocations are relatively even across the pool of running queries. If there's
a large gap between the total and biggest and the total is relatively high, more
queries have large memory allocations. And if the total is low, all the queries have
small resident sets.

Note that a wide gap may reflect many concurrent queries -- compare with the executing
count on the "Overpass query pipeline" graph to separate a crowded pool from
individually heavy queries.

### osm_mem_status

#### Dispatcher granted memory

This is an older version of the "Dispatcher claimed memory" graph, retained for
compatibility. If you don't have old Munin data you'd like to preserve, choose the
`osm_dispatcher` version instead.

### osm_nginx_access

#### nginx HTTP response codes

This graph shows the distribution of HTTP response codes returned by nginx. Note that
query parsing and execution errors are returned as HTTP 200 responses.

| Code | Path | Source | Reason |
| - | - | - | - |
| 200 | /api/interpreter | Overpass | Query started and either completed or failed with a runtime error (out of memory, timeout, query execution error) |
| 200 | /liveness | nginx (container only) | Container is live (but not necessarily healthy) |
| 302 | /api/interpreter | Overpass | Query specified redirect using `out:custom` |
| 400 | /api/interpreter | Overpass | Malformed Overpass query input |
| 400 | /api/xapi | Overpass | Malformed XAPI query input |
| 403 | /api/interpreter | Overpass | Requesting origin is blacklisted |
| 404 | * | nginx | Not Found |
| 429 | /api/interpreter | Overpass | Client is rate limited (if configured) |
| 429 | /api/* | nginx | Global rate limit, per-client connection limit, or per-client request-rate limit exceeded (if configured) |
| 504 | /api/interpreter | Overpass | Query content is blacklisted |
| 504 | /api/* | Overpass | `dispatcher` offline |
| 504 | /api/* | nginx | CGI request timeout |

The 429 response source can be distinguished by comparing to the "rate_limited" line
in the "Overpass API request count" graph. The 429 responses sent by Overpass are
counted there; while 429 responses sent by nginx are not.

Likewise, a significant volume of 504 responses may be distinguishable by comparing
the "started" and "completed" lines in the "Overpass API request count" graph, where a
gap between the two suggests query content blacklisting.

Depending on the context, each of these response codes may be appropriate and normal.
Consider investigating unusual patterns in response codes.

#### nginx egress bytes

This graph shows the total number of bytes returned in HTTP responses from nginx. It
is useful to compare this with the `osm_interpreter` and `osm_dispatcher` plugins to
estimate response sizes. However, small error message bodies can alter the ratios.

#### nginx average response size

This graph shows the average size of an HTTP response from nginx. The average includes
both query responses and error responses. Consider that small error message bodies can
alter this number when interpreting the graph.

#### Overpass nginx requests by endpoint

This graph shows the number of requests directed to each of the specific URL paths
served by nginx in the container. High request rates for paths other than
`/api/interpreter` may indicate unusual activity.

#### nginx response latency

This graph shows the total request time (including connection queuing and outbound
response transfer) and the upstream response time (which is the total processing time
for the Overpass interpreter through CGI). A divergence between the two means an
increase in request queue time or an increase in response transmission time.

#### Overpass nginx distinct API clients

This graph shows the number of distinct IP addresses that have accessed `/api/*`. This
graph is best read in conjunction with the "Overpass nginx API client concentration"
graph.

#### Overpass nginx API client concentration

This graph shows the share of query requests and response bytes for the top client and
top 10 clients respectively. Read in conjunction with the "Overpass nginx distinct API
clients" graph. A high number of distinct API clients with a low top client share is
broad organic demand. A high top client share with a low number of distinct API
clients suggests very strong client concentration.

### osm_nginx_queue

This graph shows the number of `fcgiwrap` workers that are currently executing and the
number of requests queued in nginx waiting for a CGI worker. Together, this is a view
of the Overpass request pipeline. Queries that are being processed are assigned to
`fcgiwrap` workers. Queries that are waiting to be processes are in the queue in
nginx.

It is normal and healthy to have a small to moderate queue of pending requests in
nginx. A small queue helps keep the `fcgiwrap` workers fully utilized by ensuring
there is always a new request ready to go when a previous request completes. A
moderate queue allows nginx to hold requests without executing them and trades an
increase in latency for reduced 429 rate limiting responses.

A large queue in nginx indicates that many requests are waiting without executing.
This increases latency and overall query time for clients.

The "worker limit" shows the maximum number of `fcgiwrap` workers available. And the
"connection limit" shows the point at which nginx will return 429 responses for
rate limiting. See `overpass.env` for information on how to adjust these parameters.

#### Overpass query pipeline

### osm_nginx_status

This plugin collects nginx process status information.

#### nginx connections

This graph shows the current number of open connections to nginx.

#### nginx connection rate

This graph shows the number of new connections to nginx opened per minute. Connection
reuse allows the number of open connections to remain the same over time even without
additional new connections. This can make the graph look "spiky" when a client starts
a batch of sequential queries.

### osm_timeout_status

#### Dispatcher granted time units

This is an older version of the "Dispatcher claimed time units" graph, retained for
compatibility. If you don't have old Munin data you'd like to preserve, choose the
`osm_dispatcher` version instead.
