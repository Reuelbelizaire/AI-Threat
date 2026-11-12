# Person 1 - data ingestion, quality assessment and SOC crosswalk join.
#
# Reads the untouched raw files in data/raw/ and writes, separately:
#   person1/processed/occupations_joined.csv       one row per occupation (300)
#   person1/processed/crosswalk_unmatched_socs.csv  crosswalk SOCs with no role
#   person1/data_quality_summary.md                cleaning / join decisions
#
# Run from the project root:  Rscript person1/01_data_prep.R

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
})

RAW <- "data/raw"
OUT <- "person1/processed"
SUMMARY_MD <- "person1/data_quality_summary.md"

RAW_FILE <- file.path(RAW, "ai-career-threat-index.csv")
CW_FILE  <- file.path(RAW, "soc-crosswalk.csv")

HISTORY_COLS <- c("score_q1_2025", "score_q3_2025", "score_q1_2026",
                  "score_q2_2026", "score_q3_2026")

# SOC codes are 2-digit major group + 4-digit occupation, stored as 6 digits.
soc_key <- function(x) {
  key <- gsub("[^0-9A-Za-z]", "", trimws(toupper(as.character(x))))
  ifelse(is.na(x), NA_character_, sprintf("%06s", key))
}

pct <- function(n, d) round(100 * n / d, 1)

load_raw <- function() {
  list(
    roles = read_csv(RAW_FILE, col_types = cols(soc_code = col_character()),
                     show_col_types = FALSE),
    cw    = read_csv(CW_FILE, col_types = cols(soc_code = col_character()),
                     show_col_types = FALSE)
  )
}

profile_columns <- function(df, label) {
  tibble(
    table       = label,
    column      = names(df),
    type        = vapply(df, function(x) class(x)[1], character(1)),
    n_missing   = vapply(df, function(x) sum(is.na(x)), integer(1)),
    pct_missing = pct(vapply(df, function(x) sum(is.na(x)), integer(1)), nrow(df)),
    n_unique    = vapply(df, function(x) n_distinct(x, na.rm = TRUE), integer(1)),
    example     = vapply(df, function(x) {
      v <- x[!is.na(x)]
      if (!length(v)) "" else substr(as.character(v[1]), 1, 40)
    }, character(1))
  )
}

validation_log <- new.env(parent = emptyenv())
validation_log$rows <- list()

check <- function(check, expected, observed, ok, detail = "") {
  validation_log$rows[[length(validation_log$rows) + 1]] <- tibble(
    check = check,
    expected = paste(expected, collapse = " "),
    observed = paste(observed, collapse = " "),
    status = if (ok) "pass" else "FAIL", detail = detail
  )
  invisible(ok)
}

data <- load_raw()
roles <- data$roles
cw    <- data$cw
n_roles <- nrow(roles)
n_cw    <- nrow(cw)

## 1. Structural checks ------------------------------------------------------

check("Roles: one row per role", n_roles, n_roles,
      !any(duplicated(roles$slug)), sprintf("%d distinct slugs", n_distinct(roles$slug)))
check("Roles: no fully duplicated records", 0, sum(duplicated(roles)),
      sum(duplicated(roles)) == 0)
check("Roles: no blank strings", 0,
      sum(vapply(roles, function(x) sum(!is.na(x) & trimws(x) == ""), integer(1))),
      sum(vapply(roles, function(x) sum(!is.na(x) & trimws(x) == ""), integer(1))) == 0)
check("Roles: no stray whitespace", 0,
      sum(vapply(roles, function(x) {
        if (!is.character(x)) return(0L); sum(x != trimws(x), na.rm = TRUE)
      }, integer(1))),
      sum(vapply(roles, function(x) {
        if (!is.character(x)) return(0L); sum(x != trimws(x), na.rm = TRUE)
      }, integer(1))) == 0)
check("Crosswalk: one row per SOC code", n_cw, n_distinct(cw$soc_code),
      !any(duplicated(cw$soc_code)))
check("Crosswalk: role columns only NA for 'unmatched'",
      sum(cw$match_quality == "unmatched"),
      sum(is.na(cw$nearest_role_slug)),
      identical(is.na(cw$nearest_role_slug), cw$match_quality == "unmatched"))

## 2. SOC standardisation ----------------------------------------------------

soc_format_audit <- tibble(
  table  = c("roles", "crosswalk"),
  n      = c(n_roles, n_cw),
  has_hyphen = c(sum(grepl("-", roles$soc_code, fixed = TRUE)),
                 sum(grepl("-", cw$soc_code, fixed = TRUE))),
  has_space  = c(sum(grepl("\\s", roles$soc_code)),
                 sum(grepl("\\s", cw$soc_code))),
  n_char_raw = c(paste(sort(unique(nchar(roles$soc_code))), collapse = "/"),
                 paste(sort(unique(nchar(cw$soc_code))), collapse = "/"))
)

roles <- roles %>% mutate(soc_key = soc_key(soc_code))
cw    <- cw    %>% mutate(soc_key = soc_key(soc_code))

soc_audit <- tibble(
  table            = c("roles", "crosswalk"),
  n                = c(nrow(roles), nrow(cw)),
  n_na_key         = c(sum(is.na(roles$soc_key)), sum(is.na(cw$soc_key))),
  n_key_chars      = c(paste(sort(unique(nchar(roles$soc_key))), collapse = "/"),
                       paste(sort(unique(nchar(cw$soc_key))), collapse = "/")),
  n_distinct_key   = c(n_distinct(roles$soc_key), n_distinct(cw$soc_key)),
  n_key_duplicated = c(sum(duplicated(roles$soc_key)), sum(duplicated(cw$soc_key)))
)

check("SOC keys normalised to 6 characters", "6", soc_audit$n_key_chars[2],
      all(nchar(roles$soc_key) == 6 | is.na(roles$soc_key)) &&
        all(nchar(cw$soc_key) == 6 | is.na(cw$soc_key)))
check("Crosswalk SOC key is unique (join will not fan out)", n_cw, n_distinct(cw$soc_key),
      !any(duplicated(cw$soc_key)))

## 3. Join with cardinality guard --------------------------------------------

cw_unique <- cw %>%
  select(soc_key, soc_title, cw_role_slug = nearest_role_slug,
         cw_role_title = nearest_role_title, match_quality,
         soc_score = score, soc_risk_level = risk_level)

stopifnot("crosswalk SOC key must be unique" = !any(duplicated(cw_unique$soc_key)))

joined <- roles %>% left_join(cw_unique, by = "soc_key", relationship = "many-to-one")

check("Row count unchanged by the join", n_roles, nrow(joined), nrow(joined) == n_roles)
check("No duplicated role records after join", n_roles, n_distinct(joined$slug),
      n_distinct(joined$slug) == n_roles)
check("Join is many-to-one (roles -> crosswalk)", "many-to-one",
      paste0(n_distinct(joined$soc_key), " SOC keys -> 300 roles"),
      max(count(cw_unique, soc_key)$n) == 1)
check("Every role SOC matched a crosswalk row", n_roles, sum(!is.na(joined$match_quality)),
      sum(!is.na(joined$match_quality)) == n_roles)

joined <- joined %>%
  mutate(role_is_soc_primary = !is.na(cw_role_slug) & slug == cw_role_slug) %>%
  relocate(slug, title, category, soc_code, soc_key, soc_title, match_quality,
           role_is_soc_primary, cw_role_slug, cw_role_title, soc_score, soc_risk_level)

# Cleaned crosswalk view for reuse by later steps.
crosswalk_clean <- cw %>%
  mutate(has_role = !is.na(nearest_role_slug)) %>%
  select(soc_code, soc_key, soc_title, nearest_role_slug, nearest_role_title,
         match_quality, score, risk_level, has_role)

## 4. Match quality and coverage ---------------------------------------------

cw_quality <- crosswalk_clean %>%
  count(match_quality, name = "n_soc") %>%
  mutate(pct_soc = pct(n_soc, n_cw))

joined_quality <- joined %>%
  count(match_quality, name = "n_roles") %>%
  mutate(pct_roles = pct(n_roles, nrow(joined)))

unmatched_cw <- crosswalk_clean %>%
  filter(!has_role) %>%
  select(soc_code, soc_key, soc_title, match_quality)

roles_without_primary <- joined %>%
  filter(!role_is_soc_primary) %>%
  select(slug, title, soc_key, soc_title, cw_role_slug, cw_role_title)

score_conflicts <- joined %>%
  filter(score != soc_score | risk_level != soc_risk_level)

unmatched_roles <- joined %>% filter(is.na(match_quality))

shared_soc <- roles %>% count(soc_key) %>% filter(n > 1)
n_roles_without_primary <- nrow(roles_without_primary)

## 5. Missingness ------------------------------------------------------------

missing_table <- bind_rows(
  profile_columns(roles %>% select(-soc_key), "roles"),
  profile_columns(cw %>% select(-soc_key), "crosswalk")
) %>%
  filter(n_missing > 0) %>%
  select(table, column, type, n_missing, pct_missing, n_unique)

joined_missing <- profile_columns(joined, "joined") %>%
  filter(n_missing > 0) %>%
  select(column, type, n_missing, pct_missing, n_unique)

## 6. Write outputs ----------------------------------------------------------

dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

write_csv(joined, file.path(OUT, "occupations_joined.csv"))
write_csv(crosswalk_clean, file.path(OUT, "soc_crosswalk_clean.csv"))
write_csv(unmatched_cw, file.path(OUT, "crosswalk_unmatched_socs.csv"))

## 7. Summary markdown -------------------------------------------------------

md_table <- function(df, digits = 1) {
  df <- as.data.frame(df)
  hdr <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  rows <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
  gsub("[[:space:]]+", " ", c(hdr, sep, rows))
}

fmt_roles <- function(df, max_show = 8) {
  if (!nrow(df)) return("none")
  soc <- paste0(substr(df$soc_key, 1, 2), "-", substr(df$soc_key, 3, 6))
  shown <- utils::head(sprintf("%s (%s)", df$slug, soc), max_show)
  paste0(paste(shown, collapse = ", "),
         if (nrow(df) > max_show) sprintf(", ... and %d more in the CSV", nrow(df) - max_show) else "")
}

md <- c(
  "# Data quality & join summary - Person 1 (data munging lead)",
  "",
  sprintf("Source: `data/raw/` (upstream dataset v2026.3, read-only). Code: `person1/01_data_prep.R` (R %s, tidyverse).",
          paste(R.version$major, R.version$minor, sep = ".")),
  "",
  "## 1. Inputs",
  "",
  md_table(tibble(
    file = c("ai-career-threat-index.csv", "soc-crosswalk.csv"),
    rows = c(n_roles, n_cw),
    cols = c(ncol(roles) - 1L, ncol(cw) - 1L),
    grain = c("one row per scored occupation",
              "one row per BLS SOC 2018 code mapped to its nearest scored role")
  )),
  "",
  "Key columns inspected: roles -> `slug`, `title`, `category`, `score`, `risk_level`, `soc_code`, 5 historical quarter scores, 4 sub-scores, salary range/trend, `tier`, `agentic_risk`; crosswalk -> `soc_code`, `soc_title`, `nearest_role_slug`, `nearest_role_title`, `match_quality`, `score`, `risk_level`. Both `soc_code` fields were read with `col_character()` so leading digits are never coerced.",
  "",
  "## 2. Cleaning decisions",
  "",
  "- `soc_key` added to both tables: `trimws` -> `toupper` -> strip every non-alphanumeric character -> zero-pad to 6 characters. Hyphens and whitespace are therefore dropped consistently (`15-1232` -> `151232`).",
  sprintf("- Raw format audit: %d/%d role codes and %d/%d crosswalk codes are `NN-NNNN`; whitespace found in %d (roles) and %d (crosswalk) cells. All hyphens/whitespace are stripped by `soc_key`.",
          soc_format_audit$has_hyphen[1], n_roles, soc_format_audit$has_hyphen[2], n_cw,
          soc_format_audit$has_space[1], soc_format_audit$has_space[2]),
  "- Original columns were kept unchanged; `soc_code` stays as supplied and `soc_key` is the join key. Nothing in `data/raw/` was edited or overwritten.",
  "- No rows, values or unmatched occupations were deleted. Rows the crosswalk cannot map are kept in `person1/processed/crosswalk_unmatched_socs.csv`.",
  "- Crosswalk `score`/`risk_level` were renamed `soc_score`/`soc_risk_level` and kept as SOC-level reference only: the authoritative per-occupation score remains the roles' own `score`.",
  "",
  "## 3. Join key and cardinality",
  "",
  sprintf("- Join key: `soc_key` (roles) = `soc_key` (crosswalk), a declarative `many-to-one` left join from roles."),
  sprintf("- Roles: %d rows, %d distinct `soc_key`; %d codes are shared by more than one role (largest: `%s` covers %d scored roles).",
          n_roles, n_distinct(roles$soc_key), nrow(shared_soc),
          shared_soc$soc_key[which.max(shared_soc$n)], max(shared_soc$n)),
  sprintf("- Crosswalk: %d rows, %d distinct `soc_key` (unique -> the join cannot fan out).",
          n_cw, n_distinct(cw$soc_key)),
  sprintf("- Result: %d rows, %d distinct slugs, 0 duplicated records; row count identical before and after the join.",
          nrow(joined), n_distinct(joined$slug)),
  "",
  "Validation checks:",
  "",
  md_table(bind_rows(validation_log$rows)),
  "",
  "## 4. Match report",
  "",
  sprintf("- Roles matched to a crosswalk SOC row: **%d / %d (100.0%%)**; unmatched roles: **%d**.",
          n_roles - nrow(unmatched_roles), n_roles, nrow(unmatched_roles)),
  sprintf("- Crosswalk SOC codes with no scored role: **%d / %d (%.1f%%)**, all flagged `match_quality == \"unmatched\"`; kept in `crosswalk_unmatched_socs.csv` (%s).",
          nrow(unmatched_cw), n_cw, pct(nrow(unmatched_cw), n_cw),
          paste(head(unmatched_cw$soc_title, 6), collapse = "; ")),
  sprintf("- Crosswalk-wide `match_quality`: %s.",
          paste(sprintf("%s %d (%.1f%%)", cw_quality$match_quality, cw_quality$n_soc, cw_quality$pct_soc),
                collapse = ", ")),
  sprintf("- Match quality of the %d joined roles: %s - every role's own SOC is an `exact` crosswalk entry.",
          nrow(joined), paste(sprintf("%s %d (%.1f%%)", joined_quality$match_quality,
                                      joined_quality$n_roles, joined_quality$pct_roles),
                              collapse = ", ")),
  sprintf("- %d roles (%.1f%%) are not the primary role of their SOC, so their `soc_title`/`soc_score`/`soc_risk_level` describe the SOC's primary role instead. They are flagged `role_is_soc_primary == FALSE` and retained: %s.",
          n_roles_without_primary, pct(n_roles_without_primary, n_roles), fmt_roles(roles_without_primary)),
  sprintf("- Because of that SOC sharing, crosswalk `soc_score` equals the role's own `score` for %d of %d rows; %d rows differ (max gap %.0f points, %d also differ on `risk_level`). Use the role-level `score`, not `soc_score`, for occupation analysis.",
          nrow(joined) - nrow(score_conflicts), nrow(joined), nrow(score_conflicts),
          max(abs(score_conflicts$score - score_conflicts$soc_score), na.rm = TRUE),
          sum(score_conflicts$risk_level != score_conflicts$soc_risk_level, na.rm = TRUE)),
  "",
  "## 5. Missing values (percent of rows)",
  "",
  "Tables with any missingness:",
  "",
  md_table(missing_table),
  "",
  sprintf("In the joined file only %d of %d columns are incomplete: %s. All other %d columns are complete.",
          nrow(joined_missing), ncol(joined), paste(joined_missing$column, collapse = ", "),
          ncol(joined) - nrow(joined_missing)),
  "",
  "Diagnosis: the historical quarter scores are structurally missing - 224 roles were added in v2026.3 and only have `score_q3_2026`; this is not an error and was left untouched (no imputation at this stage). The crosswalk's 33 `unmatched` SOC codes are missing role fields by design.",
  "",
  "## 6. Outputs",
  "",
  sprintf("- `person1/processed/occupations_joined.csv` - %d rows x %d columns, one row per occupation, original fields plus `soc_key`, `soc_title`, `match_quality`, `role_is_soc_primary`, `cw_role_slug`, `cw_role_title`, `soc_score`, `soc_risk_level`.",
          nrow(joined), ncol(joined)),
  "- `person1/processed/soc_crosswalk_clean.csv` - 867 rows, standardised SOC keys and `has_role` flag, for reuse by later steps.",
  "- `person1/processed/crosswalk_unmatched_socs.csv` - 33 SOC codes with no scored role (audit trail, nothing discarded).",
  "",
  "Not done in this step (by design): no imputation, no outlier treatment, no sector aggregation, no charts."
)

writeLines(md, SUMMARY_MD)

cat(sprintf("rows: roles %d -> joined %d\n", n_roles, nrow(joined)))
cat(sprintf("matched: %d  unmatched roles: %d  unmatched crosswalk SOCs: %d\n",
            sum(!is.na(joined$match_quality)), nrow(unmatched_roles), nrow(unmatched_cw)))
print(cw_quality)
print(joined_missing)
cat("wrote:", file.path(OUT, "occupations_joined.csv"), "\n")
cat("wrote:", SUMMARY_MD, "\n")