<h1 align="center">LLM Relief Dispatch Simulation</h1>

<p align="center">
	<img alt="Status" src="https://img.shields.io/badge/status-simulation-blue?" />
	<img alt="NetLogo" src="https://img.shields.io/badge/NetLogo-model-76B900?logo=netlogo&logoColor=white" />
	<img alt="Python" src="https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white" />
	<img alt="Ollama" src="https://img.shields.io/badge/Ollama-LLM_Engine-000000?logo=ollama&logoColor=white" />
	<img alt="Pandas" src="https://img.shields.io/badge/Pandas-data%20analysis-150458?logo=pandas&logoColor=white" />
	<img alt="Matplotlib" src="https://img.shields.io/badge/Matplotlib-figures-11557C?logo=matplotlib&logoColor=white" />
	<img alt="NetworkX" src="https://img.shields.io/badge/NetworkX-graphs-2C3E50" />
</p>

This project compares two dispatch strategies for a post-earthquake relief delivery model:

- Rule-based dispatch and routing
- LLM-assisted dispatch and routing using a local Ollama model

The simulation is implemented in NetLogo, the LLM helper functions are in Python, and the figures are generated from the saved CSV output.

## Project Files

- [LLM_Relief_Dispatch.nlogo](LLM_Relief_Dispatch.nlogo) contains the NetLogo model, simulation logic, and CSV export.
- [ollama_agent.py](ollama_agent.py) contains the Python helper functions used by NetLogo for routing and dispatch decisions.
- [figure_gen.py](figure_gen.py) reads the final CSV file and generates publication-style figures.
- [data/](data) contains the demand, travel time, time window, and risk inputs used by the model.
- [figures/](figures) is the output folder for generated charts.

## Workflow

1. Run the NetLogo model.
2. The simulation writes its iteration-level output to `results.csv`.
3. When you are ready to preserve a run, save or rename the desired output as `final result.csv`.
4. Run [figure_gen.py](figure_gen.py) to generate the figures from `final result.csv`.

## Important CSV Difference

`results.csv` is the live simulation output file. It is recreated each time the model initializes results, so it is the changing file during repeated simulation runs.

`final result.csv` is the saved snapshot you want to keep for analysis and plotting. The figure generator is configured to read this file directly, so if you want charts from a specific run, that run must be preserved under this name.

In short: use `results.csv` while the simulation is running, then copy or rename the chosen run to `final result.csv` before generating figures.

## What the Model Produces

Each row in the exported CSV represents one iteration-policy pair and includes:

- Demand totals and delivery outcomes
- On-time, late, unmet, and failed demand measures
- Service and failure rates
- Final simulation time
- Dispatch and routing decision counts
- Average decision time in seconds
- Completion status

## Figure Generation

[figure_gen.py](figure_gen.py) expects `final result.csv` in the project root and saves figures into [figures/](figures) as both PNG and PDF files.

The script currently generates:

- Average demand outcomes by policy
- Mean delivery performance rates
- Deadline failure rate across iterations
- Decision latency with caching enabled
- Iteration-level win counts

## Requirements

### NetLogo

- NetLogo with CSV and Python extensions enabled
- A working Python interpreter configured for NetLogo's Python bridge

### Python packages

Install the Python dependencies used by the helper script and figure generator:

```bash
pip install requests networkx pandas numpy matplotlib
```

## Ollama Setup

The LLM-assisted policy uses a local Ollama server.

1. Start Ollama.
2. Pull the model referenced by [ollama_agent.py](ollama_agent.py).
3. Make sure Ollama is reachable at `http://localhost:11434`.

If Ollama is unavailable, the helper functions fall back to the built-in heuristics, but the LLM-assisted path will not behave as intended.

## Running The Project

1. Open [LLM_Relief_Dispatch.nlogo](LLM_Relief_Dispatch.nlogo) in NetLogo.
2. Run the desired experiment mode.
3. Let the model export `results.csv`.
4. Copy the run you want to keep to `final result.csv`.
5. Run [figure_gen.py](figure_gen.py) to generate charts in [figures/](figures).

## Notes

- The simulation uses the files in [data/](data) as fixed inputs.
- The figure script is intentionally tied to `final result.csv` so you can preserve one chosen run for plotting.
- If you want the figure script to read a different filename automatically, that can be changed later, but the current workflow assumes the saved file is named exactly `final result.csv`.
