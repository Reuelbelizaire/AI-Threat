# Data quality & join summary - Person 1 (data munging lead)

Source: `data/raw/` (upstream dataset v2026.3, read-only). Code: `person1/01_data_prep.R` (R 4.6.1, tidyverse).

## 1. Inputs

| file | rows | cols | grain |
|---|---|---|---|
| ai-career-threat-index.csv | 300 | 26 | one row per scored occupation |
| soc-crosswalk.csv | 867 | 7 | one row per BLS SOC 2018 code mapped to its nearest scored role |

Key columns inspected: roles -> `slug`, `title`, `category`, `score`, `risk_level`, `soc_code`, 5 historical quarter scores, 4 sub-scores, salary range/trend, `tier`, `agentic_risk`; crosswalk -> `soc_code`, `soc_title`, `nearest_role_slug`, `nearest_role_title`, `match_quality`, `score`, `risk_level`. Both `soc_code` fields were read with `col_character()` so leading digits are never coerced.

## 2. Cleaning decisions

- `soc_key` added to both tables: `trimws` -> `toupper` -> strip every non-alphanumeric character -> zero-pad to 6 characters. Hyphens and whitespace are therefore dropped consistently (`15-1232` -> `151232`).
- Raw format audit: 300/300 role codes and 867/867 crosswalk codes are `NN-NNNN`; whitespace found in 0 (roles) and 0 (crosswalk) cells. All hyphens/whitespace are stripped by `soc_key`.
- Original columns were kept unchanged; `soc_code` stays as supplied and `soc_key` is the join key. Nothing in `data/raw/` was edited or overwritten.
- No rows, values or unmatched occupations were deleted. Rows the crosswalk cannot map are kept in `person1/processed/crosswalk_unmatched_socs.csv`.
- Crosswalk `score`/`risk_level` were renamed `soc_score`/`soc_risk_level` and kept as SOC-level reference only: the authoritative per-occupation score remains the roles' own `score`.

## 3. Join key and cardinality

- Join key: `soc_key` (roles) = `soc_key` (crosswalk), a declarative `many-to-one` left join from roles.
- Roles: 300 rows, 248 distinct `soc_key`; 29 codes are shared by more than one role (largest: `151252` covers 10 scored roles).
- Crosswalk: 867 rows, 867 distinct `soc_key` (unique -> the join cannot fan out).
- Result: 300 rows, 300 distinct slugs, 0 duplicated records; row count identical before and after the join.

Validation checks:

| check | expected | observed | status | detail |
|---|---|---|---|---|
| Roles: one row per role | 300 | 300 | pass | 300 distinct slugs |
| Roles: no fully duplicated records | 0 | 0 | pass | |
| Roles: no blank strings | 0 | 0 | pass | |
| Roles: no stray whitespace | 0 | 0 | pass | |
| Crosswalk: one row per SOC code | 867 | 867 | pass | |
| Crosswalk: role columns only NA for 'unmatched' | 33 | 33 | pass | |
| SOC keys normalised to 6 characters | 6 | 6 | pass | |
| Crosswalk SOC key is unique (join will not fan out) | 867 | 867 | pass | |
| Row count unchanged by the join | 300 | 300 | pass | |
| No duplicated role records after join | 300 | 300 | pass | |
| Join is many-to-one (roles -> crosswalk) | many-to-one | 248 SOC keys -> 300 roles | pass | |
| Every role SOC matched a crosswalk row | 300 | 300 | pass | |

## 4. Match report

- Roles matched to a crosswalk SOC row: **300 / 300 (100.0%)**; unmatched roles: **0**.
- Crosswalk SOC codes with no scored role: **33 / 867 (3.8%)**, all flagged `match_quality == "unmatched"`; kept in `crosswalk_unmatched_socs.csv` (First-Line Supervisors of Farming, Fishing, and Forestry Workers; Agricultural Inspectors; Animal Breeders; Graders and Sorters, Agricultural Products; Agricultural Equipment Operators; Farmworkers and Laborers, Crop, Nursery, and Greenhouse).
- Crosswalk-wide `match_quality`: approximate 215 (24.8%), close 371 (42.8%), exact 248 (28.6%), unmatched 33 (3.8%).
- Match quality of the 300 joined roles: exact 300 (100.0%) - every role's own SOC is an `exact` crosswalk entry.
- 52 roles (17.3%) are not the primary role of their SOC, so their `soc_title`/`soc_score`/`soc_risk_level` describe the SOC's primary role instead. They are flagged `role_is_soc_primary == FALSE` and retained: devops-engineer (15-1252), data-engineer (15-1252), mobile-developer (15-1252), site-reliability-engineer (15-1252), platform-engineer (15-1252), data-scientist (15-2051), machine-learning-engineer (15-1252), security-engineer (15-1212), ... and 44 more in the CSV.
- Because of that SOC sharing, crosswalk `soc_score` equals the role's own `score` for 250 of 300 rows; 50 rows differ (max gap 38 points, 21 also differ on `risk_level`). Use the role-level `score`, not `soc_score`, for occupation analysis.

## 5. Missing values (percent of rows)

Tables with any missingness:

| table | column | type | n_missing | pct_missing | n_unique |
|---|---|---|---|---|---|
| roles | score_q1_2025 | numeric | 224 | 74.7 | 26 |
| roles | score_q3_2025 | numeric | 224 | 74.7 | 33 |
| roles | score_q1_2026 | numeric | 224 | 74.7 | 35 |
| roles | score_q2_2026 | numeric | 224 | 74.7 | 28 |
| crosswalk | nearest_role_slug | character | 33 | 3.8 | 248 |
| crosswalk | nearest_role_title | character | 33 | 3.8 | 248 |
| crosswalk | score | numeric | 33 | 3.8 | 70 |
| crosswalk | risk_level | character | 33 | 3.8 | 4 |

In the joined file only 4 of 34 columns are incomplete: score_q1_2025, score_q3_2025, score_q1_2026, score_q2_2026. All other 30 columns are complete.

Diagnosis: the historical quarter scores are structurally missing - 224 roles were added in v2026.3 and only have `score_q3_2026`; this is not an error and was left untouched (no imputation at this stage). The crosswalk's 33 `unmatched` SOC codes are missing role fields by design.

## 6. Outputs

- `person1/processed/occupations_joined.csv` - 300 rows x 34 columns, one row per occupation, original fields plus `soc_key`, `soc_title`, `match_quality`, `role_is_soc_primary`, `cw_role_slug`, `cw_role_title`, `soc_score`, `soc_risk_level`.
- `person1/processed/soc_crosswalk_clean.csv` - 867 rows, standardised SOC keys and `has_role` flag, for reuse by later steps.
- `person1/processed/crosswalk_unmatched_socs.csv` - 33 SOC codes with no scored role (audit trail, nothing discarded).

Not done in this step (by design): no imputation, no outlier treatment, no sector aggregation, no charts.
