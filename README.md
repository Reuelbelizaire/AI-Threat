# AI-Threat — AI Career Threat Index (Data Munging group project)

Analysis of the [AI Career Threat Index](https://github.com/Jott2121/ai-career-threat-index)
(MIT licence, v2026.3): 300 US occupations scored 0-100 on estimated AI displacement risk.
Research question: which occupations are most exposed to AI displacement, and what factors
are associated with higher exposure?

## Data

Raw files are preserved unmodified in `data/raw/` (downloaded from the upstream repository):
`ai-career-threat-index.csv`, `ai-career-threat-index.json`, `soc-crosswalk.csv`.

## Reproduce

```bash
Rscript requirements.R        # install R packages (readr, dplyr, jsonlite, ggplot2, patchwork)
Rscript src/data_quality.R    # Step 2: data quality assessment
```

Outputs are written to `outputs/tables/` and `outputs/figures/`; the narrative for Step 2 is
in `data_quality_report.md`. Nothing in `data/raw/` is ever edited.

## Status

- Step 2 (data quality assessment): complete.
- Steps 3-4 (munging, EDA) and the final report: not started.
