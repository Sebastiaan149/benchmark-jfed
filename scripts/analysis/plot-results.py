#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


def analyze_result_set(results_root: Path, benchmark_dir: Path, benchmark_name: str):
    averages_file = results_root / "averages.csv"
    network_file = results_root / "network-averages.csv"
    clients_file = results_root / "network-clients.csv"
    for path in (averages_file, network_file, clients_file):
        if not path.is_file():
            raise FileNotFoundError(path)

    averages = pd.read_csv(averages_file, sep=";")
    network = pd.read_csv(network_file, sep=";")
    network_clients = pd.read_csv(clients_file, sep=";")
    dataset_rows = []
    for size in sorted(averages["size"].unique()):
        manifest_path = benchmark_dir / "data" / size / "manifest.json"
        if not manifest_path.is_file():
            raise FileNotFoundError(manifest_path)
        manifest = json.loads(manifest_path.read_text())
        required = ("triples", "regularPartitions", "typedPartitions")
        missing = [field for field in required if field not in manifest]
        if missing:
            raise ValueError(f"Missing dataset statistics {missing} in {manifest_path}; prepare the dataset again")
        dataset_rows.append({
            "size": size,
            "triples": manifest["triples"],
            "regularPartitions": manifest["regularPartitions"],
            "typedPartitions": manifest["typedPartitions"],
        })
    dataset_statistics = pd.DataFrame(dataset_rows)
    dataset_statistics.to_csv(results_root / "dataset-statistics.csv", index=False)
    plot_dir = results_root / "plots"
    plot_dir.mkdir(exist_ok=True)

    for size in ("1m", "10m", "50m", "100m"):
        subset = averages[(averages["size"] == size) & (averages["cacheMode"] == "cold")]
        if subset.empty:
            continue
        figure, axis = plt.subplots(figsize=(11, 6))
        for framework, values in subset.groupby("framework"):
            values = values.sort_values("concurrency")
            axis.plot(values["concurrency"], values["avgQueryTimeMs"], marker="o", label=framework)
        axis.set(
            xlabel="Concurrent clients",
            ylabel="Average complete result time (ms)",
            title=f"WatDiv {size}, cold cache",
        )
        if subset["concurrency"].max() > 1:
            axis.set_xscale("log", base=2)
        axis.grid(True, alpha=0.3)
        axis.legend(fontsize=8, ncol=2)
        figure.tight_layout()
        figure.savefig(plot_dir / f"query-time-{size}-cold.png", dpi=160)
        plt.close(figure)

    summary_columns = [
        "size",
        "framework",
        "cacheMode",
        "concurrency",
        "iterations",
        "querySelection",
        "queryCount",
        "clientCpuMax",
        "clientMemoryMax",
        "avgFirstResultTimeMs",
        "avgQueryTimeMs",
        "clientAvgCpuPercent",
        "clientAvgRssMb",
        "serverAvgCpuPercent",
        "serverAvgRssMb",
    ]
    report = averages[summary_columns].merge(dataset_statistics, on="size", how="left").sort_values(
        ["size", "framework", "cacheMode", "concurrency"],
    )
    report.to_csv(results_root / "report-summary.csv", index=False)

    print(f"{benchmark_name}: averages={len(averages)}, network={len(network)}, clients={len(network_clients)}")
    print(f"Datasets: {results_root / 'dataset-statistics.csv'}")
    print(f"Plots: {plot_dir}")
    print(f"Summary: {results_root / 'report-summary.csv'}")
    return averages, network, network_clients, report, dataset_statistics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=["smoke-1m", "full"])
    parser.add_argument("--benchmark-dir", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    profile_root = args.benchmark_dir / "watdiv-results" / args.profile
    if args.profile == "smoke-1m":
        analyze_result_set(profile_root, args.benchmark_dir, "smoke-1m")
        return

    benchmarks = (
        ("single-unlimited", profile_root / "single-unlimited"),
        ("concurrent-limited", profile_root / "concurrent-limited"),
    )
    combined_averages = []
    combined_network = []
    combined_clients = []
    combined_reports = []
    dataset_statistics = None
    for name, result_root in benchmarks:
        averages, network, clients, report, current_statistics = analyze_result_set(
            result_root,
            args.benchmark_dir,
            name,
        )
        combined_averages.append(averages.assign(benchmark=name))
        combined_network.append(network.assign(benchmark=name))
        combined_clients.append(clients.assign(benchmark=name))
        combined_reports.append(report.assign(benchmark=name))
        dataset_statistics = current_statistics

    pd.concat(combined_averages, ignore_index=True).to_csv(profile_root / "combined-averages.csv", index=False)
    pd.concat(combined_network, ignore_index=True).to_csv(profile_root / "combined-network-averages.csv", index=False)
    pd.concat(combined_clients, ignore_index=True).to_csv(profile_root / "combined-network-clients.csv", index=False)
    pd.concat(combined_reports, ignore_index=True).to_csv(profile_root / "combined-report-summary.csv", index=False)
    dataset_statistics.to_csv(profile_root / "dataset-statistics.csv", index=False)
    print(f"Combined summary: {profile_root / 'combined-report-summary.csv'}")


if __name__ == "__main__":
    main()
