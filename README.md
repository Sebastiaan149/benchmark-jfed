# jFed WatDiv Benchmark

This repository runs the WatDiv benchmark on four Virtual Wall 1 bare-metal nodes:

| Node | Hardware | Experiment IP | Role |
| --- | --- | --- | --- |
| `server0` | `pcgen07-1p` | `10.0.1.2` | Generates data and runs one server at a time |
| `client0` | `pcgen07-1p` | `10.0.1.11` | Controller and logical client IDs 1-22 |
| `client1` | `pcgen07-1p` | `10.0.1.12` | Logical client IDs 23-43 |
| `client2` | `pcgen07-1p` | `10.0.1.13` | Logical client IDs 44-64 |

All four nodes use Ubuntu 24.04 and one uncapped experiment LAN. Only `client0` needs to clone this repository. There are no execution notebooks.

## 1. Create The jFed Experiment

1. Open jFed Experimenter.
2. Load [`rspec/wall1-four-pcgen07-1p-ubuntu24.rspec`](rspec/wall1-four-pcgen07-1p-ubuntu24.rspec).
3. Verify that it shows four exclusive `pcgen07-1p` raw PCs and one LAN.
4. Start the experiment and wait until all nodes are ready.
5. Open an SSH terminal to `client0`.

The RSpec requests `pcgen07-1p` explicitly. It does not contain a substitute hardware type or VM fallback.

## 2. Clone On client0

On `client0`, run:

```bash
sudo mkdir -p /local/masterproef_repos
sudo chown "$(id -un):$(id -gn)" /local/masterproef_repos
git clone https://github.com/Sebastiaan149/benchmark-jfed.git /local/masterproef_repos/benchmark-jfed
cd /local/masterproef_repos/benchmark-jfed
```

## 3. Authorize client0

Generate a controller key and print the authorization command:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/controller-key.sh generate
```

Open jFed SSH terminals to `server0`, `client1`, and `client2`. Paste the printed command into each of those three terminals. Then verify from `client0`:

```bash
./scripts/jfed/controller-key.sh verify
```

The verification must reach all three nodes and confirm passwordless `sudo` before deployment continues.

## 4. Deploy And Install

Run on `client0`:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/deploy-cluster.sh
```

This command:

- Copies this repository from `client0` to the other three nodes.
- Installs Node.js 20, Yarn, Java 21, Maven, Docker, HDT build tools, network tools, measurement tools, Python analysis packages, and system dependencies.
- Clones and builds all server repositories only on `server0`.
- Clones and builds Comunica on the three client nodes.
- Verifies six CPU cores, at least 60 GB RAM, cgroup v2, required commands, LAN reachability, Comunica HDT support, Java, Maven, and Docker.

To synchronize later benchmark-script changes without reinstalling repositories, run on `client0`:

```bash
cd /local/masterproef_repos/benchmark-jfed
git pull --ff-only
./scripts/jfed/sync-benchmark.sh
```

If a previous build left modified or generated files in one of the cloned repositories, perform a clean workspace reinstall. This removes all repositories, prepared data, logs, and results under `/local/masterproef_repos`, but keeps the controller SSH key in `~/.ssh`.

First remove the remote workspaces from `client0`:

```bash
cd /local/masterproef_repos/benchmark-jfed
source config/cluster.env

for host in "$SERVER_SSH" $CLIENT_SSHS; do
  ssh "$host" '
    sudo rm -rf /local/masterproef_repos
    sudo install -d -o "$(id -un)" -g "$(id -gn)" /local/masterproef_repos
  '
done
```

Then recreate the workspace on `client0` and deploy again:

```bash
cd /local
sudo rm -rf /local/masterproef_repos
sudo install -d -o "$(id -un)" -g "$(id -gn)" /local/masterproef_repos
git clone https://github.com/Sebastiaan149/benchmark-jfed.git /local/masterproef_repos/benchmark-jfed
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/controller-key.sh verify
./scripts/jfed/deploy-cluster.sh
```

Reprovision the nodes through jFed instead when the operating system and installed packages must also be reset.

## 5. One-Client 1M Check

First prepare only the 1M dataset on `server0`:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/prepare-data.sh smoke-1m
```

Then run every configured framework with one logical client, one iteration, and the five selected WatDiv queries:

```bash
./scripts/jfed/run-profile.sh smoke-1m
```

This profile creates only logical client ID 1 on `client0`. It does not start clients on `client1` or `client2` and does not run the 64-stream network calibration.

Analyze and package the smoke results:

```bash
./scripts/jfed/analyze-results.sh smoke-1m
./scripts/jfed/pack-results.sh
```

Inspect `watdiv-results/smoke-1m/averages.csv`, `report-summary.csv`, and `plots/` before starting the full experiment.

## 6. Full Benchmark

Prepare 1M, 10M, 50M, and 100M sequentially on `server0`:

```bash
cd /local/masterproef_repos/benchmark-jfed
./scripts/jfed/prepare-data.sh full
```

Run the full benchmark:

```bash
./scripts/jfed/run-profile.sh full
```

The full profile removes earlier `full/` results and then runs two benchmarks over `1m 10m 50m 100m`. Both include the existing query timing, result count, client/server CPU and RAM, and per-client network measurements.

The first benchmark writes to `watdiv-results/full/single-unlimited/`:

- One logical client on `client0`.
- One iteration.
- 50 queries: the first 50 queries from the deterministic 100-query selection.
- No client CPU or cgroup RAM limit; the client may use all six cores and available memory.
- The logical client link is limited to `100 Mbit/s`.

The second benchmark writes to `watdiv-results/full/concurrent-limited/`:

- Concurrency: `1 2 4 8 16 32 64`.
- One iteration.
- Ten queries per client: `C1`, `C2`, `F1`, `F2`, `L1`, `L2`, `S1`, `S2`, `S6`, and `S7` (instance 1).
- Physical client capacities: `22 21 21`.
- Per logical client: `0.15` CPU core, `896 MiB` RAM, and `20 Mbit/s`.

For both benchmarks:

- SmartKG, SmartKG+, and WiseKG: cold and warm cache runs.
- Warm-cache queries run before server and network monitoring starts; only the following measured queries contribute metrics.
- Other frameworks: cold cache runs.
- One server process at a time, with the previous process fully stopped before the next starts.
- Timeout-only combinations and a small minority of failed queries are retained in `benchmark-attempt-failures.csv` and detailed in `benchmark-query-failures.csv`; missing results, widespread processing errors, and failed server processes stop the run.

Before the query matrix, three simultaneous `iperf3` tests use 22, 21, and 21 streams and write their results under `watdiv-results/full/calibration/`.

Analyze and package the full results:

```bash
./scripts/jfed/analyze-results.sh full
./scripts/jfed/pack-results.sh
```

Download the resulting archive from `benchmark-jfed/downloads/` through jFed or SCP before releasing the experiment.

## Data And Storage

The server preparation pipeline generates WatDiv NT, dataset HDT and index, characteristic sets, regular partitions, typed partitions, and the Passage journal. It uses the original `getFamilies` partitioning only.

- SmartKG and WiseKG use `partitioning/`.
- SmartKG+ uses `typed-partitioning/`.
- Each partition `.nt` file is deleted after its indexed HDT conversion succeeds; complete metadata validation follows conversion.
- `dataset.nt` remains for endpoint serving, class extraction, and Passage preparation.
- There is no NT-dump benchmark; local dump querying uses HDT.
- Preparation requires at least 350 GiB free before starting 100M.
- Every physical client has roughly 469 GiB usable SSD storage. A maximum of 22 simultaneous 100M HDT downloads is expected to require roughly 14 GB, and the actual file-size preflight remains authoritative.

## Measurements And Results

All results remain under `benchmark-jfed/watdiv-results/` on `client0`:

- `smoke-1m/`: one-client validation results.
- `full/single-unlimited/`: one-iteration, 50-query unrestricted single-client results.
- `full/concurrent-limited/`: one-iteration limited concurrency-matrix results.
- `full/combined-*.csv`: analysis tables combining both full benchmarks with a `benchmark` column.
- `query-times.csv`: time to first result, complete response time, result count, process-tree CPU, and RSS.
- `client-netns.csv`: RX/TX bytes and packet counters for each logical client.
- `server-metrics/`: server process-tree CPU and RAM samples.
- `averages.csv`: iteration-level aggregates.
- `network-averages.csv`: aggregate bytes, packets, and throughput.
- `network-clients.csv`: network measurements per logical client.
- `benchmark-attempt-failures.csv`: failed benchmark combinations and whether they were recoverable or fatal.
- `benchmark-query-failures.csv`: individual failed queries with timeout, exit, signal, stderr, and server-log references.
- `dataset-statistics.csv`: triple, regular-partition, and typed-partition counts per dataset size.
- `plots/` and `report-summary.csv`: terminal-generated analysis output.

The scripts use monotonic Node.js timing, process-tree sampling, cgroup v2, network namespaces, interface counters, `tc`, `iptables`, `iperf3`, `sysstat`, and `tcpdump`.

## Release The Experiment

After downloading the result archive, stop or delete the experiment in jFed Experimenter. Resource release is intentionally not performed by a shell script.
