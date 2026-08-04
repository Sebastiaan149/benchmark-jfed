#!/usr/bin/env python3
import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=["smoke-1m", "full"])
    parser.add_argument("--benchmark-dir", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    results_root = args.benchmark_dir / "watdiv-results" / args.profile
    averages_file = results_root / "averages.csv"
    network_file = results_root / "network-averages.csv"
    clients_file = results_root / "network-clients.csv"
    for path in (averages_file, network_file, clients_file):
        if not path.is_file():
            raise FileNotFoundError(path)

    averages = pd.read_csv(averages_file, sep=";")
    network = pd.read_csv(network_file, sep=";")
    network_clients = pd.read_csv(clients_file, sep=";")
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
        "avgFirstResultTimeMs",
        "avgQueryTimeMs",
        "clientAvgCpuPercent",
        "clientAvgRssMb",
        "serverAvgCpuPercent",
        "serverAvgRssMb",
    ]
    averages[summary_columns].sort_values(
        ["size", "framework", "cacheMode", "concurrency"],
    ).to_csv(results_root / "report-summary.csv", index=False)

    print(f"Rows: averages={len(averages)}, network={len(network)}, clients={len(network_clients)}")
    print(f"Plots: {plot_dir}")
    print(f"Summary: {results_root / 'report-summary.csv'}")


if __name__ == "__main__":
    main()
