# jFed WatDiv Benchmark

Runs the WatDiv benchmark on four Virtual Wall 1 Ubuntu 24.04 nodes:

| Node | IP | Role |
| --- | --- | --- |
| `server0` | `10.0.1.2` | Data preparation and benchmark servers |
| `client0` | `10.0.1.11` | Controller and clients 1-22 |
| `client1` | `10.0.1.12` | Clients 23-43 |
| `client2` | `10.0.1.13` | Clients 44-64 |

Run all commands below from an SSH terminal on `client0`. The repository is
named `benchmark-jfed`, not `jfed-benchmark`.

## 1. Create The Cluster

In jFed Experimenter, load
[`rspec/wall1-four-pcgen07-1p-ubuntu24.rspec`](rspec/wall1-four-pcgen07-1p-ubuntu24.rspec),
start the experiment, and wait for all four nodes.

## 2. Clone The Benchmark

```bash
sudo install -d -o "$(id -un)" -g "$(id -gn)" /local/masterproef_repos
git clone https://github.com/Sebastiaan149/benchmark-jfed.git /local/masterproef_repos/benchmark-jfed
cd /local/masterproef_repos/benchmark-jfed
```

## 3. Configure Cluster SSH

```bash
./scripts/jfed/controller-key.sh generate
```

Paste the printed authorization command into separate jFed SSH terminals for
`server0`, `client1`, and `client2`. Then verify from `client0`:

```bash
./scripts/jfed/controller-key.sh verify
```

## 4. Install And Verify

This deploys the benchmark and installs the server/client software on every
node:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/deploy-cluster.sh
```

To rerun only the local `client0` setup:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/setup/client.sh
```

Verify the cluster at any time with:

```bash
./scripts/jfed/verify-cluster.sh
```

## 5. Update The Cluster

Synchronize committed benchmark changes from `client0` to the other nodes:

```bash
cd /local/masterproef_repos/benchmark-jfed
git pull --ff-only
./scripts/jfed/sync-benchmark.sh
```

After pushing Comunica changes, pull and rebuild Comunica on every client:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/sync-benchmark.sh
./scripts/setup/client.sh

source config/cluster.env
for target in $CLIENT_SSHS; do
  ssh -o BatchMode=yes "$target" \
    "cd '$REMOTE_CLIENT_BENCHMARK_DIR' && ./scripts/setup/client.sh"
done

./scripts/jfed/verify-cluster.sh
```

## 6. Run The 1M Cold-Cache Check

Prepare the data, then run one unrestricted client using only SmartKG,
SmartKG+, WiseKG, and SPF:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/prepare-data.sh smoke-1m

FRAMEWORKS="smartkg smartkg-plus wisekg spf" \
CACHE_MODES="cold" \
  ./scripts/jfed/run-profile.sh smoke-1m
```

Analyze and package the results:

```bash
./scripts/jfed/analyze-results.sh smoke-1m
./scripts/jfed/pack-results.sh
```

Download the archive from `downloads/` before deleting any results.

## 7. Remove The 1M Check Results

After confirming the archive was downloaded:

```bash
cd /local/masterproef_repos/benchmark-jfed
source config/cluster.env

sudo rm -rf "$BENCHMARK_DIR/watdiv-results/smoke-1m"
for target in "$SERVER_SSH" $CLIENT_SSHS; do
  ssh -o BatchMode=yes "$target" \
    "sudo rm -rf '$REMOTE_BENCHMARK_DIR/watdiv-results/smoke-1m'"
done
```

This removes smoke results only; it keeps the prepared dataset.

## 8. Run The Full Benchmark

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/prepare-data.sh full
./scripts/jfed/run-profile.sh full
./scripts/jfed/analyze-results.sh full
./scripts/jfed/pack-results.sh
```

The full profile runs:

- One unrestricted client with all 20 template queries, iterated three times.
- `1, 2, 4, 8, 16, 32, 64` limited concurrent clients with five queries each.
- Dataset sizes `1M`, `10M`, `50M`, and `100M`.

### Persistent JBR/Comunica clients

Every logical client starts one JBR query runner and one local Comunica HTTP
endpoint per benchmark iteration. All queries assigned to that client and
iteration are sent to the same endpoint worker. The endpoint is selected from
the framework configuration (`query-sparql`, SmartKG, WiseKG, SPF, Passage, or
HDT), so the SPARQL-endpoint baseline also runs through
`comunica-sparql-http`. Comunica module loading, endpoint startup, worker
creation, and startup-time V8 work happen before the first measured query.
The endpoint is stopped after the iteration.

JBR uses `sparql-benchmark-runner` for its WatDiv and SPARQL-custom query
execution. The benchmark adapter reuses that runner's binding parser and
single-query execution method while placing measurement callbacks around each
individual query. `timeMs` begins immediately before JBR sends that query and
ends when the parsed binding stream ends. `firstResultTimeMs` is the timestamp
of the first parsed RDF binding, not the arrival of the first response bytes.
`results` and `resultHash` are likewise calculated from parsed bindings.

The existing `query-times.csv` columns remain stable. Additional columns record
the persistent execution mode, result hash, endpoint-process CPU time, and
per-query network byte/packet deltas. CPU/RAM sampling covers the persistent
Comunica endpoint master and worker only; it excludes endpoint/V8 startup and
the small JBR HTTP driver. Per-query network deltas exclude loopback traffic
between JBR and the local Comunica endpoint and are emitted when logical-client
network namespaces are enabled. The existing `client-netns.csv` stage counters
and server resource measurements remain unchanged.

Passage journals are generated as a triple store using Blazegraph `DiskRW`.
Regenerate an older Passage journal after changing these settings; changing the
properties file does not convert an existing `DiskWORM` journal.

Each limited logical client receives the same cgroup limits: 0.25 CPU core and
2 GiB RAM, with a 1536 MiB Node.js old-space limit. At the largest 22-client
node allocation this reserves at most 5.5 of 6 cores and 44 of 56 GiB, leaving
capacity for the operating system and benchmark controller.

The concurrency profile additionally runs an nginx reverse-cache partner for every network framework except `ldf-dump-hdt`. Each cached partner is measured twice at every concurrency level: first with a cold-on-start nginx cache, and then as `server-warm` by reusing the cache populated by that cold measurement. No separate warm-up workload is needed. Client caches are cold and isolated in the uncached baseline and both nginx measurements, so each network framework has exactly three server-cache conditions and `server-warm` refers only to the shared nginx cache.

The cache key includes the request method, URI, request body, `Accept`, and content type. Nginx locks simultaneous cache misses and records `HIT`, `MISS`, and related statuses in run-labelled access logs. GET, HEAD, and POST responses are cacheable; other methods are proxied without caching. The same nginx and origin-server processes remain active between the cold and warm measurements, retaining both the response cache and the server filesystem page cache for `server-warm`. Client runtime directories and the nginx access log are separated between measurements, and the server caches are cleared after the pair before the next concurrency level. The single-client performance profile continues to use only uncached variants.

Analysis writes per-framework request counts, HIT/MISS totals, and hit ratios to `nginx-cache-stats.csv`. The one-second raw samples are also converted into `server-resource-timeseries.csv` and `network-timeseries.csv` for plotting the transition from no nginx, through cold cache population, to the reused warm cache. Both files identify the framework family, cache condition, concurrency, stage number, elapsed time within the stage, and a continuous timeline position across all three stages. The server timeline contains CPU percentage, RSS memory, process count, and PID, while the network timeline contains per-second RX/TX bytes, packets, Mbit/s, and cumulative totals within each stage and across the complete three-stage experiment.

For `ldf-dump-hdt`, each logical client downloads the HDT file and index once
per iteration and reuses that private copy for every query in the iteration.
Namespace network monitoring includes the download and query execution. Client
CPU/RAM query samples begin after preparation, and static-server CPU/RAM samples
are retained only while at least one HDT response body is being transferred.

Results are stored in `watdiv-results/full/`; the downloadable archive is
created in `downloads/`.

## 9. Finish

Download the result archive, then stop or delete the experiment in jFed.
