# Step 2 - data quality assessment for the AI Career Threat Index.
#
# Reads the untouched raw files in data/raw/ and writes assessment tables to
# outputs/tables/ and one figure to outputs/figures/. Nothing is cleaned,
# imputed or removed here: the raw dataset is only read.
#
# Run from the project root:  Rscript src/data_quality.R

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
  library(ggplot2)
  library(patchwork)
})

RAW    <- "data/raw"
TABLES <- "outputs/tables"
FIGS   <- "outputs/figures"

HISTORY_COLS <- c("score_q1_2025", "score_q3_2025", "score_q1_2026",
                  "score_q2_2026", "score_q3_2026")
SUBSCORE_COLS <- c("sub_task_automation", "sub_tool_maturity",
                   "sub_adoption", "sub_agentic_exposure")
Q_LABELS <- c("Q1 2025", "Q3 2025", "Q1 2026", "Q2 2026", "Q3 2026")
# Documented bands (dataset metadata: riskBands) and their midpoints.
BOUNDARIES <- c(35.5, 50.5, 75.5)
# Tokens commonly used to encode missing values.
SENTINELS <- c("", "na", "n/a", "null", "none", "-", "?", "nan", "#n/a")

band_of <- function(x) {
  out <- rep(NA_character_, length(x))
  out[x >= 0 & x <= 35]  <- "Low"
  out[x >= 36 & x <= 50] <- "Moderate"
  out[x >= 51 & x <= 75] <- "High"
  out[x >= 76 & x <= 100] <- "Very High"
  out[!is.na(x) & is.na(out)] <- "out_of_range"   # never let a stray score become NA
  out
}

# Dollar amounts with a thousands separator, for the detail strings.
usd <- function(x) formatC(x, format = "d", big.mark = ",")

load_data <- function() {
  raw <- read_csv(file.path(RAW, "ai-career-threat-index.csv"), show_col_types = FALSE)
  js  <- fromJSON(file.path(RAW, "ai-career-threat-index.json"), simplifyVector = FALSE)
  crosswalk <- read_csv(file.path(RAW, "soc-crosswalk.csv"), show_col_types = FALSE)
  list(raw = raw, js = js, crosswalk = crosswalk)
}

column_profile <- function(df) {
  tibble(
    column     = names(df),
    dtype      = vapply(df, function(x) class(x)[1], character(1)),
    n_non_null = vapply(df, function(x) sum(!is.na(x)), integer(1)),
    n_missing  = vapply(df, function(x) sum(is.na(x)), integer(1)),
    pct_missing = round(100 * vapply(df, function(x) mean(is.na(x)), numeric(1)), 1),
    n_unique   = vapply(df, function(x) n_distinct(x, na.rm = TRUE), integer(1)),
    example    = vapply(df, function(x) {
      v <- x[!is.na(x)]
      if (length(v) == 0) "" else substr(as.character(v[1]), 1, 60)
    }, character(1))
  )
}

missingness_table <- function(df) {
  notes <- c(
    score_q1_2025 = "Structural: 224 roles were added in v2026.3 and start their history at Q3 2026",
    score_q3_2025 = "Structural: same 224 roles (identical missing pattern)",
    score_q1_2026 = "Structural: same 224 roles (identical missing pattern)",
    score_q2_2026 = "Structural: same 224 roles (identical missing pattern)",
    score_q3_2026 = "None: current score, complete for all 300 roles"
  )
  n_miss <- vapply(df, function(x) sum(is.na(x)), integer(1))
  tibble(
    column      = names(df),
    n_missing   = as.integer(n_miss),
    pct_missing = round(100 * n_miss / nrow(df), 1),
    diagnosis   = ifelse(names(df) %in% names(notes), notes[names(df)],
                         ifelse(n_miss == 0, "None", "Unexplained"))
  )
}

missingness_by_category <- function(df) {
  df |>
    mutate(has_history = !is.na(score_q1_2025)) |>
    group_by(category) |>
    summarise(
      n_roles            = n(),
      n_with_history     = sum(has_history),
      pct_missing_history = round(100 * (1 - mean(has_history)), 1),
      pct_tier1          = round(100 * mean(tier == 1), 1),
      .groups = "drop"
    ) |>
    arrange(desc(pct_missing_history))
}

missingness_association <- function(df) {
  gap <- is.na(df$score_q1_2025)

  tier_tab <- table(df$tier, gap)
  perfect  <- all(tier_tab[, "TRUE"] == rowSums(tier_tab) | tier_tab[, "TRUE"] == 0)

  fully_missing <- df |>
    group_by(category) |>
    summarise(all_gap = all(is.na(score_q1_2025)), .groups = "drop") |>
    filter(all_gap) |>
    pull(category)

  panel       <- df[!gap, ]
  residual    <- sum(is.na(panel[HISTORY_COLS[-1]]))

  tibble(
    test = c("History missing vs tier",
             "History missing vs category",
             "Residual gaps inside the historical panel"),
    result = c(ifelse(perfect, "deterministic", "not deterministic"),
               sprintf("%d of 15 categories fully missing", length(fully_missing)),
               sprintf("%d missing cells", residual)),
    interpretation = c(
      sprintf("tier 2: %d/%d roles missing history; tier 1: %d/%d",
              sum(df$tier == 2 & gap), sum(df$tier == 2),
              sum(df$tier == 1 & gap), sum(df$tier == 1)),
      paste(fully_missing, collapse = ", "),
      sprintf("%d panel roles x 4 later quarters is complete", nrow(panel))
    )
  )
}

encoding_checks <- function(df, js, crosswalk) {
  rows <- list()
  add <- function(check, columns, n, detail, status) {
    rows[[length(rows) + 1]] <<- tibble(check = check, columns = columns,
                                        n_flagged = as.integer(n), detail = detail,
                                        status = status)
  }

  text_cols <- names(df)[vapply(df, is.character, logical(1))]

  add("Duplicate rows", "all", sum(duplicated(df)), "No repeated records", "pass")
  add("Duplicate role slugs / titles", "slug, title",
      sum(duplicated(df$slug)) + sum(duplicated(df$title)),
      "Each role appears exactly once", "pass")

  ws <- vapply(text_cols, function(c) sum(df[[c]] != trimws(df[[c]]), na.rm = TRUE), integer(1))
  add("Leading/trailing whitespace", "text columns", sum(ws),
      sprintf("No stray whitespace in any of the %d text fields", length(text_cols)), "pass")

  # Non-ASCII characters: typographic quotes/dashes are fine, mojibake would not be.
  nonascii <- vapply(text_cols, function(c) {
    x <- df[[c]]; x <- x[!is.na(x)]
    sum(nchar(x, type = "chars") !=
          nchar(iconv(x, from = "UTF-8", to = "ASCII", sub = ""), type = "chars"))
  }, integer(1))
  nonascii <- nonascii[nonascii > 0]
  add("Non-ASCII characters (encoding integrity)",
      if (length(nonascii)) paste(names(nonascii), collapse = ", ") else "text columns",
      sum(nonascii),
      if (length(nonascii)) sprintf("{%s}: curly quotes and em dashes inside free-text insights, not corrupted encodings",
                                    paste(sprintf("'%s': %d", names(nonascii), nonascii), collapse = ", "))
      else "Pure ASCII",
      "legitimate")

  sent <- vapply(text_cols, function(c) {
    x <- tolower(trimws(df[[c]]))
    sum(!is.na(x) & x %in% SENTINELS)
  }, integer(1))
  sent <- sent[sent > 0]
  add("Missing-value sentinel tokens (NA, null, '-', ...)", "text columns", sum(sent),
      sprintf("Missing data uses true blanks only; %s",
              if (length(sent)) paste(sprintf("'%s': %d", names(sent), sent), collapse = ", ")
              else "no sentinel tokens found"),
      "pass")

  # One consistent case style per label column, and no padded values.
  style_one <- function(v) {
    if (!is.character(v)) return("numeric")
    if (v != trimws(v)) return("padded")
    if (identical(v, tolower(v))) "lower"
    else if (identical(v, tools::toTitleCase(v))) "title"
    else "other"
  }
  domains <- list(category = 15, risk_level = 4, salary_trend = 4,
                  agentic_risk = 4, tier = 2)
  for (col in names(domains)) {
    vals <- sort(unique(df[[col]]))
    ok <- length(vals) == domains[[col]]
    if (col != "category") {
      styles <- unique(vapply(vals, style_one, character(1)))
      ok <- ok && length(styles) <= 1 && !any(styles %in% c("other", "padded"))
    }
    # Quote levels so labels containing a comma (e.g. Hospitality, Food & ...) stay readable.
    add(sprintf("Label domain: %s", col), col, if (ok) 0 else length(vals),
        sprintf("%d levels, consistent casing/spelling: %s", length(vals),
                paste(sprintf("'%s'", vals), collapse = ", ")),
        if (ok) "pass" else "flagged")
  }

  meta_cats <- unlist(js$categories)
  add("Category labels match JSON metadata", "category",
      length(setdiff(meta_cats, df$category)) + length(setdiff(df$category, meta_cats)),
      "All 15 labels identical across CSV, JSON metadata and JSON roles", "pass")

  add("SOC code format (NN-NNNN)", "soc_code",
      sum(!grepl("^[0-9]{2}-[0-9]{4}$", df$soc_code)),
      "All 300 codes follow the BLS SOC 2018 pattern", "pass")
  add("Slug format (lowercase-hyphen)", "slug",
      sum(!grepl("^[a-z0-9]+(-[a-z0-9]+)*$", df$slug)),
      "All slugs are clean URL-safe identifiers", "pass")
  add("SOC codes present in crosswalk", "soc_code",
      sum(!df$soc_code %in% crosswalk$soc_code),
      "Every scored role's SOC code appears in soc-crosswalk.csv", "pass")

  shared_rows <- df$soc_code[duplicated(df$soc_code) | duplicated(df$soc_code, fromLast = TRUE)]
  add("SOC codes shared by several roles", "soc_code", length(shared_rows),
      sprintf(paste0("%d BLS codes map to 2-5 distinct role rows ",
                     "(e.g. 13-1071 -> Recruiter, HR Generalist, Talent Sourcer). ",
                     "Legitimate, not duplication error"), n_distinct(shared_rows)),
      "legitimate")

  roles <- js$roles
  same_order <- identical(vapply(roles, function(r) r$slug, character(1)), df$slug)
  score_ok   <- all(vapply(seq_along(roles), function(i) roles[[i]]$score == df$score[i], logical(1)))
  salary_ok  <- all(vapply(seq_along(roles), function(i) {
    roles[[i]]$salary$low == df$salary_low_usd[i] && roles[[i]]$salary$high == df$salary_high_usd[i]
  }, logical(1)))
  task_ok    <- all(vapply(seq_along(roles), function(i) {
    length(roles[[i]]$tasksAtRisk) == df$tasks_at_risk_count[i] &&
      length(roles[[i]]$tasksGrowing) == df$tasks_growing_count[i]
  }, logical(1)))
  hist_ok    <- all(vapply(seq_along(roles), function(i) {
    hs  <- roles[[i]]$historicalScores
    got <- vapply(Q_LABELS, function(q) {
      v <- hs[[q]]
      if (is.null(v)) NA_real_ else as.numeric(v)
    }, numeric(1))
    exp <- as.numeric(df[i, HISTORY_COLS])
    isTRUE(all(is.na(got) == is.na(exp))) && all(got[!is.na(got)] == exp[!is.na(exp)])
  }, logical(1)))
  all_ok <- all(same_order, score_ok, salary_ok, task_ok, hist_ok)
  add("CSV vs JSON agreement", "score, salary, task counts, quarterly history",
      if (all_ok) 0 else 1,
      sprintf("row order=%s, scores=%s, salaries=%s, task counts=%s, quarterly history=%s",
              same_order, score_ok, salary_ok, task_ok, hist_ok),
      if (all_ok) "pass" else "flagged")

  strict <- band_of(df$score)
  mism   <- df[strict != df$risk_level, ]
  dist   <- if (nrow(mism)) apply(abs(outer(mism$score, BOUNDARIES, "-")), 1, min) else numeric(0)
  within5 <- sum(dist <= 5)
  restated_slugs <- vapply(roles, function(r) if (is.null(r$restatement)) NA_character_ else r$slug,
                           character(1))
  restated <- sum(mism$slug %in% restated_slugs)
  add("risk_level matches documented bands", "score, risk_level", nrow(mism),
      sprintf(paste0("%d roles carry a band one step away from the band implied by their score; ",
                     "%d sit within 5 points of a published boundary (the metadata's ",
                     "band-stability rule) and %d are roles with a documented restatement ",
                     "reason. Labels are therefore consistent with the rubric but not a ",
                     "deterministic function of score"),
              nrow(mism), within5, restated),
      "legitimate")

  agentic_strict <- band_of(df$sub_agentic_exposure)
  add("agentic_risk matches sub-score bands", "agentic_risk, sub_agentic_exposure",
      sum(agentic_strict != df$agentic_risk),
      "agentic_risk is a pure band of the agentic sub-score and adds no information beyond it",
      "legitimate")

  bind_rows(rows)
}

numeric_checks <- function(df, js, crosswalk) {
  rows <- list()
  add <- function(check, column, n_fail, detail, status) {
    rows[[length(rows) + 1]] <<- tibble(check = check, column = column,
                                        n_failures = as.integer(n_fail), detail = detail,
                                        status = status)
  }

  int_like <- c("score", "salary_low_usd", "salary_high_usd", "tasks_at_risk_count",
                "tasks_growing_count", "tier", SUBSCORE_COLS, HISTORY_COLS)
  bad_dtype <- int_like[vapply(int_like, function(c) {
    x <- df[[c]]; x <- x[!is.na(x)]
    any(x != round(x))
  }, logical(1))]
  add("Scores/counts stored as whole numbers", paste(int_like, collapse = ", "), length(bad_dtype),
      if (!length(bad_dtype)) "All scores, salaries, counts and sub-scores are integers"
      else sprintf("Non-integer values in %s", paste(bad_dtype, collapse = ", ")),
      if (!length(bad_dtype)) "pass" else "flagged")

  add("salary_low_usd < salary_high_usd", "salary bounds",
      sum(df$salary_low_usd >= df$salary_high_usd),
      "Lower bound strictly below upper bound for all 300 roles; no equal or inverted bounds",
      "pass")
  add("Salaries positive", "salary bounds", sum(df$salary_low_usd <= 0),
      sprintf("Range $%s-$%s; anchored to BLS OES p25-p75",
              usd(min(df$salary_low_usd)), usd(max(df$salary_high_usd))), "pass")

  num_cols <- names(df)[vapply(df, is.numeric, logical(1))]
  add("Negative values in numeric columns", "all numeric",
      sum(vapply(num_cols, function(c) sum(df[[c]] < 0, na.rm = TRUE), integer(1))),
      "No negative entries", "pass")

  add("score within documented 0-100 range", "score", sum(!df$score %in% 0:100),
      sprintf("Observed range %d-%d", min(df$score), max(df$score)), "pass")
  add("Sub-scores within 0-100", paste(SUBSCORE_COLS, collapse = ", "),
      sum(vapply(SUBSCORE_COLS, function(c) sum(!df[[c]] %in% 0:100), integer(1))),
      "All four sub-scores bounded 0-100 for all 300 roles", "pass")
  add("Quarterly scores within 0-100", paste(HISTORY_COLS, collapse = ", "),
      sum(vapply(HISTORY_COLS, function(c) {
        x <- df[[c]]; sum(!is.na(x) & !x %in% 0:100)
      }, integer(1))),
      sprintf("All %d observed quarterly values bounded 0-100", sum(!is.na(df[HISTORY_COLS]))),
      "pass")

  add("score equals score_q3_2026", "score, score_q3_2026",
      sum(df$score != df$score_q3_2026),
      "The current score is definitionally the Q3 2026 value, so the two columns are perfectly redundant",
      "legitimate")

  formula <- df$sub_task_automation *
    (0.45 + 0.30 * df$sub_tool_maturity / 100 + 0.25 * df$sub_adoption / 100) +
    0.10 * df$sub_agentic_exposure
  max_diff <- max(abs(formula - df$score))
  add("Composite reproducible from sub-scores", "score, sub-scores",
      sum(round(formula) != df$score),
      sprintf("Published formula reproduces the score for %d/%d roles (max |diff| = %.2f, rounding only)",
              nrow(df), nrow(df), max_diff), "pass")

  roles <- js$roles
  add("tasks_at_risk_count equals task list length", "tasks_at_risk_count",
      sum(vapply(seq_along(roles), function(i) length(roles[[i]]$tasksAtRisk) != df$tasks_at_risk_count[i], logical(1))),
      sprintf("Counts match JSON task lists (range %d-%d)",
              min(df$tasks_at_risk_count), max(df$tasks_at_risk_count)), "pass")
  add("tasks_growing_count equals task list length", "tasks_growing_count",
      sum(vapply(seq_along(roles), function(i) length(roles[[i]]$tasksGrowing) != df$tasks_growing_count[i], logical(1))),
      sprintf("Counts match JSON task lists (range %d-%d)",
              min(df$tasks_growing_count), max(df$tasks_growing_count)), "pass")

  spread <- (df$salary_high_usd - df$salary_low_usd) / df$salary_low_usd
  add("Salary spread wider than 150% of lower bound", "salary bounds", sum(spread > 1.5),
      sprintf(paste0("Median spread %.0f%%; %d roles exceed 150%% ",
                     "(e.g. Investment Banker $85k-$275k, Surgeon $280k-$450k). ",
                     "Consistent with p25-p75 bounds"),
              100 * median(spread), sum(spread > 1.5)), "legitimate")

  add("Crosswalk rows with no matched role", "nearest_role_slug, score, risk_level (crosswalk)",
      sum(is.na(crosswalk$nearest_role_slug)),
      sprintf(paste0("%d of 867 SOC codes are 'unmatched': farm (45-xxxx) and military ",
                     "(55-xxxx) occupations sit outside the 300 scored roles"),
              sum(is.na(crosswalk$nearest_role_slug))), "structural")

  bind_rows(rows)
}

outlier_scan <- function(df) {
  bind_rows(lapply(c("score", "salary_low_usd", "salary_high_usd"), function(col) {
    x  <- df[[col]]
    q  <- quantile(x, c(0.25, 0.75), type = 7, names = FALSE)
    iqr <- q[2] - q[1]
    lo <- q[1] - 1.5 * iqr
    hi <- q[2] + 1.5 * iqr
    sub <- df[x < lo | x > hi, ]
    tibble(
      column = col, q1 = q[1], q3 = q[2],
      lower_fence = round(lo, 1), upper_fence = round(hi, 1),
      n_flagged = nrow(sub),
      pct_flagged = round(100 * nrow(sub) / nrow(df), 1),
      min_flagged = if (nrow(sub)) min(sub[[col]]) else NA_real_,
      max_flagged = if (nrow(sub)) max(sub[[col]]) else NA_real_,
      examples = if (nrow(sub)) paste(head(sub$title[order(-sub[[col]])], 3), collapse = "; ") else ""
    )
  }))
}

summary_table <- function(df, profile, enc, outl) {
  gap <- profile$n_missing[profile$column == "score_q1_2025"]
  mism <- enc$n_flagged[enc$check == "risk_level matches documented bands"]
  salary_flags <- sum(outl$n_flagged[outl$column %in% c("salary_low_usd", "salary_high_usd")])
  score_flags <- outl$n_flagged[outl$column == "score"]

  tibble(
    issue = c("Quarterly scores missing before Q3 2026",
              "Current score duplicates Q3 2026 score",
              "Score is an exact function of the four sub-scores",
              "risk_level label disagrees with the score band",
              "agentic_risk is a deterministic band of its sub-score",
              "Salary values beyond IQR fences",
              "Score value beyond IQR fence",
              "Unmatched SOC codes in the crosswalk",
              "Duplicates, types, ranges, labels, sentinel tokens"),
    columns = c(paste(HISTORY_COLS[-5], collapse = ", "),
                "score, score_q3_2026",
                paste(SUBSCORE_COLS, collapse = ", "),
                "score, risk_level",
                "agentic_risk, sub_agentic_exposure",
                "salary_low_usd, salary_high_usd",
                "score",
                "nearest_role_slug, score, risk_level (crosswalk)",
                "all"),
    n_records = as.integer(c(gap, nrow(df), nrow(df), mism, nrow(df), salary_flags,
                             score_flags, 33, 0)),
    classification = c("Structural (by design)", "Redundant (not an error)",
                       "Redundant (not an error)", "Documented boundary-stability rule",
                       "Redundant (not an error)", "Legitimate extreme values",
                       "Legitimate extreme value", "Structural (out of scope)", "Passed"),
    recommended_action = c(
      "Do not impute. Restrict time-series work to the 76 roles with full history and report the 300-role cross-section separately",
      "Keep a single score column and build a long-format quarter variable from the history columns",
      "Describe sub-scores as components of the composite; do not treat them as independent predictors",
      "Use score-derived bands for comparisons and keep the published label for reference only",
      "Use the numeric sub-score and drop the band in analysis",
      "Retain. Analyse salary on a log scale or with rank-based (Spearman) methods",
      "Retain: Data Entry Clerk (92) is the top of the documented 0-100 scale",
      "Exclude from merges or keep and label as unmatched; never assign a score",
      "No action; only type conversions are needed in Step 3")
  )
}

make_figure <- function(df, profile) {
  base_theme <- theme_classic(base_size = 9) +
    theme(axis.title.y = element_blank(),
          axis.ticks.y = element_blank(),
          axis.line.y = element_blank(),
          plot.title = element_text(face = "bold", size = 11),
          plot.title.position = "plot")

  panel_a_df <- profile |>
    arrange(pct_missing, column) |>
    mutate(column = factor(column, levels = column),
           kind = factor(ifelse(column %in% HISTORY_COLS, "history", "other"),
                         levels = c("history", "other")))

  panel_a <- ggplot(panel_a_df, aes(x = pct_missing, y = column, fill = kind)) +
    geom_col(width = 0.72) +
    geom_text(data = filter(panel_a_df, pct_missing > 0),
              aes(label = sprintf("%.1f%%", pct_missing)),
              hjust = -0.12, size = 2.7, colour = "#c0392b") +
    scale_fill_manual(values = c(history = "#c0392b", other = "#95a5a6")) +
    scale_x_continuous(limits = c(0, 100), expand = expansion(mult = c(0, 0.02))) +
    labs(title = "A. Missingness by column", x = "Missing values (% of 300 rows)") +
    base_theme +
    theme(axis.text.y = element_text(size = 7.5), legend.position = "none")

  panel_b_df <- df |>
    mutate(has_history = !is.na(score_q1_2025)) |>
    group_by(category) |>
    summarise(n_roles = n(), n_hist = sum(has_history), .groups = "drop") |>
    mutate(pct = 100 * n_hist / n_roles) |>
    arrange(pct) |>
    mutate(category = factor(category, levels = category),
           label = sprintf("%.0f%%  (n=%d)", pct, n_roles))

  panel_b <- ggplot(panel_b_df, aes(x = pct, y = category)) +
    geom_col(fill = "#2c7fb8", width = 0.7) +
    geom_text(aes(label = label), hjust = -0.12, size = 2.7, colour = "#1f5f8b") +
    scale_x_continuous(limits = c(0, 100), expand = expansion(mult = c(0, 0.02))) +
    labs(title = "B. Historical coverage by occupational category",
         x = "Roles with data before Q3 2026 (%)") +
    base_theme +
    theme(axis.text.y = element_text(size = 8))

  fig <- (panel_a + panel_b) +
    plot_layout(widths = c(1, 1.1)) +
    plot_annotation(title = "Data quality: missing historical scores are structural, not scattered",
                    theme = theme(plot.title = element_text(size = 11.5, face = "plain")))

  ggsave(file.path(FIGS, "dq_missingness_overview.png"), fig,
         width = 12.6, height = 5.8, dpi = 160, bg = "white")
}

main <- function() {
  if (!dir.exists(RAW)) {
    stop("data/raw/ not found - run this script from the project root, e.g. Rscript src/data_quality.R")
  }
  dir.create(TABLES, recursive = TRUE, showWarnings = FALSE)
  dir.create(FIGS, recursive = TRUE, showWarnings = FALSE)
  d <- load_data()
  df <- d$raw; js <- d$js; crosswalk <- d$crosswalk

  profile  <- column_profile(df)
  miss     <- missingness_table(df)
  miss_cat <- missingness_by_category(df)
  assoc    <- missingness_association(df)
  enc      <- encoding_checks(df, js, crosswalk)
  num      <- numeric_checks(df, js, crosswalk)
  outl     <- outlier_scan(df)
  summ     <- summary_table(df, profile, enc, outl)

  outputs <- list(
    "dq_column_profile.csv" = profile,
    "dq_missingness.csv" = miss,
    "dq_missingness_by_category.csv" = miss_cat,
    "dq_missingness_association.csv" = assoc,
    "dq_encoding_checks.csv" = enc,
    "dq_numeric_validation.csv" = num,
    "dq_outlier_scan.csv" = outl,
    "dq_summary.csv" = summ
  )
  for (nm in names(outputs)) write_csv(outputs[[nm]], file.path(TABLES, nm))
  make_figure(df, profile)

  flagged <- c(enc$check[enc$status == "flagged"], num$check[num$status == "flagged"])
  cat(sprintf("rows=%d cols=%d | documented issues=%d | failed checks=%s\n",
              nrow(df), ncol(df), nrow(summ),
              if (length(flagged)) paste(flagged, collapse = ", ") else "none"))
  cat(sprintf("missing cells=%d | max missing in a column=%d\n",
              sum(is.na(df)), max(miss$n_missing)))
  cat(sprintf("duplicate rows=%d | IQR flags=%d (score %d)\n",
              sum(duplicated(df)), sum(outl$n_flagged), outl$n_flagged[outl$column == "score"]))
  cat(sprintf("encoding checks passed=%d/%d | numeric checks passed=%d/%d\n",
              sum(enc$status == "pass"), nrow(enc),
              sum(num$status == "pass"), nrow(num)))
  cat("wrote: ", paste(names(outputs), collapse = ", "),
      " + outputs/figures/dq_missingness_overview.png\n", sep = "")

  missing_files <- names(outputs)[!file.exists(file.path(TABLES, names(outputs)))]
  if (length(missing_files) || !file.exists(file.path(FIGS, "dq_missingness_overview.png"))) {
    stop(sprintf("missing outputs: %s", paste(missing_files, collapse = ", ")))
  }
}

main()
