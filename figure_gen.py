# ============================================================
# Matplotlib Figure Generator for Modelling and Simulation Paper
# LLM-Assisted vs Rule-Based Dispatch and Routing
#
# Input file expected in the same folder:
#   final result.csv
#
# Output:
#   fig1/*.png
#   fig2/*.pdf
# ============================================================

from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# ============================================================
# USER SETTINGS
# ============================================================

CSV_PATH = Path("final result.csv")
OUTPUT_DIR = Path("figures")
OUTPUT_DIR.mkdir(exist_ok=True)

FULL_WIDTH = (7.15, 4.05)
COMPACT_WIDTH = (5.25, 3.55)

SAVE_DPI = 600

# ============================================================
# GLOBAL MATPLOTLIB STYLE
# ============================================================

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
    "mathtext.fontset": "dejavuserif",
    "font.size": 10,
    "axes.titlesize": 12,
    "axes.labelsize": 10,
    "legend.fontsize": 9,
    "xtick.labelsize": 9,
    "ytick.labelsize": 9,
    "axes.linewidth": 0.8,
    "figure.dpi": 140,
    "savefig.dpi": SAVE_DPI,
})

# Calm publication-style colors.
RULE_COLOR = "#264653"       # deep blue-green
LLM_COLOR = "#E76F51"        # soft orange-red
TIE_COLOR = "#9E9E9E"        # neutral gray

ONTIME_COLOR = "#2A9D8F"     # teal
LATE_COLOR = "#E76F51"       # orange-red
UNMET_COLOR = "#E9C46A"      # muted gold

GRID_COLOR = "#C7C7C7"
TEXT_COLOR = "#222222"


def clean_axes(ax, grid_axis="y"):
    """Clean academic axis style."""
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color(TEXT_COLOR)
    ax.spines["bottom"].set_color(TEXT_COLOR)
    ax.tick_params(axis="both", colors=TEXT_COLOR, length=3.5, width=0.8)
    ax.grid(axis=grid_axis, linestyle="--", linewidth=0.55, alpha=0.65, color=GRID_COLOR)
    ax.set_axisbelow(True)


def outside_top_legend(fig, ax, ncol=2, y_title=0.98, y_legend=0.915, top=0.80):
    """
    Put the legend outside the plotting area, below the title.
    This prevents the legend from covering bars, lines, or labels.
    """
    handles, labels = ax.get_legend_handles_labels()
    if handles:
        fig.legend(
            handles,
            labels,
            loc="upper center",
            bbox_to_anchor=(0.5, y_legend),
            ncol=ncol,
            frameon=False,
            handlelength=1.4,
            columnspacing=1.8,
            borderaxespad=0.0,
        )
    fig.subplots_adjust(top=top)


def add_title(fig, title, y=0.985):
    """Use a figure-level title so the legend and axes can be placed cleanly."""
    fig.suptitle(title, y=y, fontsize=12, fontweight="normal", color=TEXT_COLOR)


def save_figure(fig, filename):
    """Save PNG and PDF versions."""
    png_path = OUTPUT_DIR / f"{filename}.png"
    pdf_path = OUTPUT_DIR / f"{filename}.pdf"
    fig.savefig(png_path, bbox_inches="tight", dpi=SAVE_DPI)
    fig.savefig(pdf_path, bbox_inches="tight")
    print(f"Saved: {png_path}")
    print(f"Saved: {pdf_path}")


def add_bar_labels(ax, bars, fmt="{:.0f}", offset=1.0, fontsize=8):
    """Add value labels above vertical bars."""
    for bar in bars:
        h = bar.get_height()
        if np.isnan(h):
            continue
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            h + offset,
            fmt.format(h),
            ha="center",
            va="bottom",
            fontsize=fontsize,
            color=TEXT_COLOR,
            clip_on=False,
        )


# ============================================================
# LOAD DATA
# ============================================================

# If you run this in a different folder, change CSV_PATH above.
if not CSV_PATH.exists():
    # Helpful fallback for notebook/sandbox use.
    alt_path = Path("/mnt/data/final result.csv")
    if alt_path.exists():
        CSV_PATH = alt_path
    else:
        raise FileNotFoundError(f"Could not find CSV file: {CSV_PATH}")

raw = pd.read_csv(CSV_PATH)

core_columns = [
    "iteration",
    "policy",
    "total_demand",
    "delivered_demand",
    "on_time_demand",
    "late_demand",
    "unmet_demand",
    "total_failed_demand",
    "service_rate",
    "on_time_rate",
    "late_rate",
    "unmet_rate",
    "failure_rate",
    "final_simulation_time",
    "dispatch_decisions",
    "routing_decisions",
    "avg_decision_time_seconds",
    "completion_status",
]

missing = [c for c in core_columns if c not in raw.columns]
if missing:
    raise ValueError(f"Missing required columns in CSV: {missing}")

df = raw[core_columns].copy()
df["policy"] = df["policy"].astype(str).str.strip().str.lower()

policy_order = ["rule-based", "llm-assisted"]
policy_name = {
    "rule-based": "Rule-based",
    "llm-assisted": "LLM-assisted",
}

df = df[df["policy"].isin(policy_order)].copy()

numeric_cols = [c for c in core_columns if c not in ["policy", "completion_status"]]
for col in numeric_cols:
    df[col] = pd.to_numeric(df[col], errors="coerce")

# Ensure consistent sorting.
df = df.sort_values(["iteration", "policy"]).reset_index(drop=True)

summary = df.groupby("policy").agg({
    "total_demand": "mean",
    "delivered_demand": "mean",
    "on_time_demand": "mean",
    "late_demand": "mean",
    "unmet_demand": "mean",
    "total_failed_demand": "mean",
    "service_rate": "mean",
    "on_time_rate": "mean",
    "late_rate": "mean",
    "unmet_rate": "mean",
    "failure_rate": "mean",
    "final_simulation_time": "mean",
    "dispatch_decisions": "mean",
    "routing_decisions": "mean",
    "avg_decision_time_seconds": ["mean", "median"],
})

summary.columns = [
    "_".join(col).strip("_") if isinstance(col, tuple) else col
    for col in summary.columns
]
summary = summary.loc[policy_order]

print("\nSummary by policy:")
print(summary.round(4))

# ============================================================
# FIGURE 1: AVERAGE DEMAND OUTCOMES BY POLICY
# ============================================================

labels = [policy_name[p] for p in policy_order]
x = np.arange(len(labels))
width = 0.52

on_time = summary["on_time_demand_mean"].values.astype(float)
late = summary["late_demand_mean"].values.astype(float)
unmet = summary["unmet_demand_mean"].values.astype(float)

total_stack = on_time + late + unmet

fig, ax = plt.subplots(figsize=COMPACT_WIDTH)
add_title(fig, "Average Demand Outcomes by Policy")

ax.bar(x, on_time, width, label="On-time", color=ONTIME_COLOR, edgecolor="white", linewidth=0.7)
ax.bar(x, late, width, bottom=on_time, label="Late", color=LATE_COLOR, edgecolor="white", linewidth=0.7)
ax.bar(x, unmet, width, bottom=on_time + late, label="Unmet", color=UNMET_COLOR, edgecolor="white", linewidth=0.7)

for i in range(len(labels)):
    ax.text(x[i], on_time[i] / 2, f"{on_time[i]:.2f}", ha="center", va="center", color="white", fontsize=8)
    ax.text(x[i], on_time[i] + late[i] / 2, f"{late[i]:.2f}", ha="center", va="center", color="white", fontsize=8)
    ax.text(x[i], on_time[i] + late[i] + unmet[i] / 2, f"{unmet[i]:.2f}", ha="center", va="center", color=TEXT_COLOR, fontsize=8)
    ax.text(x[i], total_stack[i] + 1.0, f"Total = {total_stack[i]:.0f}", ha="center", va="bottom", fontsize=8.5, color=TEXT_COLOR)

ax.set_ylabel("Demand units")
ax.set_xticks(x)
ax.set_xticklabels(labels)
ax.set_ylim(0, max(total_stack) * 1.16)
clean_axes(ax, "y")
outside_top_legend(fig, ax, ncol=3, y_legend=0.905, top=0.77)

save_figure(fig, "fig1_average_demand_outcomes")
plt.close(fig)

# ============================================================
# FIGURE 2: MEAN DELIVERY PERFORMANCE RATES
# ============================================================

rate_metrics = [
    ("service_rate_mean", "Service\nrate"),
    ("on_time_rate_mean", "On-time\nrate"),
    ("late_rate_mean", "Late\nrate"),
    ("unmet_rate_mean", "Unmet\nrate"),
    ("failure_rate_mean", "Deadline\nfailure rate"),
]

metric_cols = [m[0] for m in rate_metrics]
metric_labels = [m[1] for m in rate_metrics]

rule_values = summary.loc["rule-based", metric_cols].values.astype(float)
llm_values = summary.loc["llm-assisted", metric_cols].values.astype(float)

x = np.arange(len(metric_labels))
width = 0.34

fig, ax = plt.subplots(figsize=FULL_WIDTH)
add_title(fig, "Mean Delivery Performance Rates Across 100 Monte Carlo Iterations")

bars_rule = ax.bar(x - width / 2, rule_values, width, label="Rule-based", color=RULE_COLOR, edgecolor="white", linewidth=0.7)
bars_llm = ax.bar(x + width / 2, llm_values, width, label="LLM-assisted", color=LLM_COLOR, edgecolor="white", linewidth=0.7)

add_bar_labels(ax, bars_rule, fmt="{:.3f}", offset=0.014, fontsize=7.5)
add_bar_labels(ax, bars_llm, fmt="{:.3f}", offset=0.014, fontsize=7.5)

ax.set_ylabel("Rate")
ax.set_xticks(x)
ax.set_xticklabels(metric_labels)
ax.set_ylim(0, max(np.nanmax(rule_values), np.nanmax(llm_values)) * 1.22)
clean_axes(ax, "y")
outside_top_legend(fig, ax, ncol=2, y_legend=0.905, top=0.78)

save_figure(fig, "fig2_mean_delivery_performance_rates")
plt.close(fig)

# ============================================================
# FIGURE 3: DEADLINE FAILURE RATE ACROSS ITERATIONS
# ============================================================

failure = df.pivot(index="iteration", columns="policy", values="failure_rate").sort_index()
iterations = failure.index.values
rule_failure = failure["rule-based"].values.astype(float)
llm_failure = failure["llm-assisted"].values.astype(float)

rule_mean = np.nanmean(rule_failure)
llm_mean = np.nanmean(llm_failure)

fig, ax = plt.subplots(figsize=FULL_WIDTH)
add_title(fig, "Deadline Failure Rate Across 100 Paired Monte Carlo Iterations")

ax.plot(iterations, rule_failure, color=RULE_COLOR, linewidth=1.35, marker="o", markersize=3.0, markeredgewidth=0, label="Rule-based")
ax.plot(iterations, llm_failure, color=LLM_COLOR, linewidth=1.35, marker="D", markersize=3.0, markeredgewidth=0, label="LLM-assisted")

ax.axhline(rule_mean, color=RULE_COLOR, linestyle="--", linewidth=0.9, alpha=0.70)
ax.axhline(llm_mean, color=LLM_COLOR, linestyle="--", linewidth=0.9, alpha=0.70)

ax.text(101.5, rule_mean, f"Mean {rule_mean:.3f}", color=RULE_COLOR, fontsize=8, va="center")
ax.text(101.5, llm_mean, f"Mean {llm_mean:.3f}", color=LLM_COLOR, fontsize=8, va="center")

ax.set_xlabel("Monte Carlo iteration")
ax.set_ylabel("Deadline failure rate")
ax.set_xlim(1, 108)
ax.set_ylim(0, 1.0)
ax.set_xticks(np.arange(1, 101, 10))
ax.set_yticks(np.arange(0, 1.01, 0.1))
clean_axes(ax, "both")
outside_top_legend(fig, ax, ncol=2, y_legend=0.905, top=0.78)

save_figure(fig, "fig3_deadline_failure_rate_iterations")
plt.close(fig)

# ============================================================
# FIGURE 4: DECISION LATENCY WITH CACHING ENABLED
# ============================================================

latency_labels = ["Mean\ndecision time", "Median\ndecision time"]
rule_latency = np.array([
    summary.loc["rule-based", "avg_decision_time_seconds_mean"],
    summary.loc["rule-based", "avg_decision_time_seconds_median"],
], dtype=float)
llm_latency = np.array([
    summary.loc["llm-assisted", "avg_decision_time_seconds_mean"],
    summary.loc["llm-assisted", "avg_decision_time_seconds_median"],
], dtype=float)

x = np.arange(len(latency_labels))
width = 0.34

fig, ax = plt.subplots(figsize=COMPACT_WIDTH)
add_title(fig, "Decision Latency With Caching Enabled")

bars_rule = ax.bar(x - width / 2, rule_latency, width, label="Rule-based", color=RULE_COLOR, edgecolor="white", linewidth=0.7)
bars_llm = ax.bar(x + width / 2, llm_latency, width, label="LLM-assisted", color=LLM_COLOR, edgecolor="white", linewidth=0.7)

# Log scale is intentional because rule-based latency is near zero but nonzero.
ax.set_yscale("log")

for bars in [bars_rule, bars_llm]:
    for bar in bars:
        h = bar.get_height()
        ax.text(bar.get_x() + bar.get_width() / 2, h * 1.22, f"{h:.4f}", ha="center", va="bottom", fontsize=7.5, color=TEXT_COLOR, clip_on=False)

ax.set_ylabel("Seconds, log scale")
ax.set_xticks(x)
ax.set_xticklabels(latency_labels)
clean_axes(ax, "y")
outside_top_legend(fig, ax, ncol=2, y_legend=0.905, top=0.77)

save_figure(fig, "fig4_decision_latency_log_scale")
plt.close(fig)

# ============================================================
# FIGURE 5: ITERATION-LEVEL WIN COUNTS
# ============================================================

wide = df.pivot(index="iteration", columns="policy")

comparisons = [
    ("Delivered\ndemand", "delivered_demand", "higher"),
    ("Service\nrate", "service_rate", "higher"),
    ("On-time\ndemand", "on_time_demand", "higher"),
    ("Late\ndemand", "late_demand", "lower"),
    ("Unmet\ndemand", "unmet_demand", "lower"),
    ("Failed\ndemand", "total_failed_demand", "lower"),
    ("Failure\nrate", "failure_rate", "lower"),
    ("Decision\nlatency", "avg_decision_time_seconds", "lower"),
]

win_rows = []
for label, metric, direction in comparisons:
    rule = wide[metric]["rule-based"]
    llm = wide[metric]["llm-assisted"]

    if direction == "higher":
        rule_wins = int((rule > llm).sum())
        llm_wins = int((llm > rule).sum())
    else:
        rule_wins = int((rule < llm).sum())
        llm_wins = int((llm < rule).sum())

    ties = int((rule == llm).sum())
    win_rows.append([label, rule_wins, llm_wins, ties])

win_df = pd.DataFrame(win_rows, columns=["Metric", "Rule-based wins", "LLM-assisted wins", "Ties"])
print("\nIteration-level win counts:")
print(win_df.to_string(index=False))

x = np.arange(len(win_df))
width = 0.25

fig, ax = plt.subplots(figsize=(7.6, 4.2))
add_title(fig, "Iteration-Level Win Counts Across 100 Paired Runs")

bars_rule = ax.bar(x - width, win_df["Rule-based wins"], width, label="Rule-based wins", color=RULE_COLOR, edgecolor="white", linewidth=0.7)
bars_llm = ax.bar(x, win_df["LLM-assisted wins"], width, label="LLM-assisted wins", color=LLM_COLOR, edgecolor="white", linewidth=0.7)
bars_ties = ax.bar(x + width, win_df["Ties"], width, label="Ties", color=TIE_COLOR, edgecolor="white", linewidth=0.7)

add_bar_labels(ax, bars_rule, fmt="{:.0f}", offset=1.2, fontsize=7.5)
add_bar_labels(ax, bars_llm, fmt="{:.0f}", offset=1.2, fontsize=7.5)
add_bar_labels(ax, bars_ties, fmt="{:.0f}", offset=1.2, fontsize=7.5)

ax.set_ylabel("Number of iterations")
ax.set_xticks(x)
ax.set_xticklabels(win_df["Metric"])
ax.set_ylim(0, 112)
ax.set_yticks(np.arange(0, 101, 20))
clean_axes(ax, "y")

# This is the important fix: legend is outside the axes, with the axes pushed lower.
outside_top_legend(fig, ax, ncol=3, y_legend=0.905, top=0.77)

save_figure(fig, "fig5_iteration_level_win_counts")
plt.close(fig)

print(f"\nDone. Figures saved in: {OUTPUT_DIR.resolve()}")
