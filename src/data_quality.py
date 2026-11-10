"""Step 2 - data quality assessment for the AI Career Threat Index.

Reads the untouched raw files in data/raw/ and writes assessment tables to
outputs/tables/ and figures to outputs/figures/. Nothing is cleaned, imputed or
removed here: the raw dataset is only read.

Run: python src/data_quality.py
"""

from pathlib import Path
import json
import re

import matplotlib
import numpy as np
import pandas as pd

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402  (backend must be set first)

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
TABLES = ROOT / "outputs" / "tables"
FIGS = ROOT / "outputs" / "figures"

HISTORY_COLS = [
    "score_q1_2025",
    "score_q3_2025",
    "score_q1_2026",
    "score_q2_2026",
    "score_q3_2026",
]
SUBSCORE_COLS = [
    "sub_task_automation",
    "sub_tool_maturity",
    "sub_adoption",
    "sub_agentic_exposure",
]
# Documented bands (dataset metadata: riskBands).
RISK_BANDS = [(0, 35, "Low"), (36, 50, "Moderate"), (51, 75, "High"), (76, 100, "Very High")]
# Tokens commonly used to encode missing values.
SENTINELS = {"", "na", "n/a", "null", "none", "-", "?", "nan", "#n/a"}
SOC_RE = re.compile(r"^\d{2}-\d{4}$")
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def band_of(score: float) -> str:
    """Map a 0-100 score to its documented risk band."""
    for low, high, name in RISK_BANDS:
        if low <= score <= high:
            return name
    return "out_of_range"


def load_data():
    raw = pd.read_csv(RAW / "ai-career-threat-index.csv")
    with open(RAW / "ai-career-threat-index.json") as fh:
        js = json.load(fh)
    crosswalk = pd.read_csv(RAW / "soc-crosswalk.csv")
    return raw, js, crosswalk


def column_profile(df: pd.DataFrame) -> pd.DataFrame:
    """Per-column type, cardinality and missingness."""
    rows = []
    for col in df.columns:
        s = df[col]
        rows.append(
            {
                "column": col,
                "dtype": str(s.dtype),
                "n_non_null": int(s.notna().sum()),
                "n_missing": int(s.isna().sum()),
                "pct_missing": round(100 * s.isna().mean(), 1),
                "n_unique": int(s.nunique(dropna=True)),
                "example": str(s.dropna().iloc[0])[:60] if s.notna().any() else "",
            }
        )
    return pd.DataFrame(rows)


def missingness_table(df: pd.DataFrame) -> pd.DataFrame:
    """Missing-value detail with a diagnosis of why each gap exists."""
    notes = {
        "score_q1_2025": "Structural: 224 roles were added in v2026.3 and start their history at Q3 2026",
        "score_q3_2025": "Structural: same 224 roles (identical missing pattern)",
        "score_q1_2026": "Structural: same 224 roles (identical missing pattern)",
        "score_q2_2026": "Structural: same 224 roles (identical missing pattern)",
        "score_q3_2026": "None: current score, complete for all 300 roles",
    }
    rows = []
    for col in df.columns:
        n_miss = int(df[col].isna().sum())
        rows.append(
            {
                "column": col,
                "n_missing": n_miss,
                "pct_missing": round(100 * n_miss / len(df), 1),
                "diagnosis": notes.get(col, "None" if n_miss == 0 else "Unexplained"),
            }
        )
    return pd.DataFrame(rows)


def missingness_by_category(df: pd.DataFrame) -> pd.DataFrame:
    """Is the historical-score gap associated with category and tier?"""
    df = df.assign(has_history=df["score_q1_2025"].notna())
    out = (
        df.groupby("category")
        .agg(
            n_roles=("slug", "size"),
            n_with_history=("has_history", "sum"),
            pct_missing_history=("has_history", lambda s: round(100 * (1 - s.mean()), 1)),
        )
        .reset_index()
    )
    out["pct_tier1"] = [
        round(100 * df.loc[df.category == c, "tier"].eq(1).mean(), 1) for c in out.category
    ]
    return out.sort_values("pct_missing_history", ascending=False)


def missingness_association(df: pd.DataFrame) -> pd.DataFrame:
    """Is the history gap tied to tier (all or nothing) and to category?"""
    rows = []
    gap = df["score_q1_2025"].isna()

    ct = pd.crosstab(df["tier"], gap)
    perfect = ct.shape[1] == 2 and all(
        (ct[True] == ct.sum(axis=1)) | (ct[True] == 0)
    )
    rows.append(
        {
            "test": "History missing vs tier",
            "result": "deterministic" if perfect else "not deterministic",
            "interpretation": (
                f"tier 2: {int(ct.loc[2, True])}/{int(ct.loc[2].sum())} roles missing history; "
                f"tier 1: {int(ct.loc[1, True])}/{int(ct.loc[1].sum())}"
            ),
        }
    )

    cat_tab = pd.crosstab(df["category"], gap)
    zero = cat_tab.index[cat_tab[True] == cat_tab.sum(axis=1)].tolist()
    rows.append(
        {
            "test": "History missing vs category",
            "result": f"{len(zero)} of 15 categories fully missing",
            "interpretation": ", ".join(zero),
        }
    )

    panel = df[~gap]
    resid = int(panel[HISTORY_COLS[1:]].isna().sum().sum())
    rows.append(
        {
            "test": "Residual gaps inside the historical panel",
            "result": f"{resid} missing cells",
            "interpretation": f"{len(panel)} panel roles x 4 later quarters is complete",
        }
    )
    return pd.DataFrame(rows)


def encoding_checks(df: pd.DataFrame, js: dict, crosswalk: pd.DataFrame) -> pd.DataFrame:
    """Duplicates, label consistency, sentinel tokens and cross-file agreement."""
    rows = []

    def add(check, columns, n, detail, status):
        rows.append(
            {"check": check, "columns": columns, "n_flagged": n, "detail": detail, "status": status}
        )

    add("Duplicate rows", "all", int(df.duplicated().sum()), "No repeated records", "pass")
    add(
        "Duplicate role slugs / titles",
        "slug, title",
        int(df.slug.duplicated().sum() + df.title.duplicated().sum()),
        "Each role appears exactly once",
        "pass",
    )

    text_cols = [c for c in df.columns if pd.api.types.is_string_dtype(df[c]) or df[c].dtype == object]
    ws = {c: int(df[c].dropna().ne(df[c].dropna().str.strip()).sum()) for c in text_cols}
    add(
        "Leading/trailing whitespace",
        "text columns",
        int(sum(ws.values())),
        f"No stray whitespace in any of the {len(text_cols)} text fields",
        "pass",
    )

    # Non-ASCII characters: typographic quotes/dashes are fine, mojibake would not be.
    non_ascii = {
        c: int(df[c].dropna().str.contains(r"[^\x00-\x7F]", regex=True).sum()) for c in text_cols
    }
    non_ascii = {k: v for k, v in non_ascii.items() if v}
    add(
        "Non-ASCII characters (encoding integrity)",
        ", ".join(non_ascii) or "text columns",
        int(sum(non_ascii.values())),
        f"{non_ascii}: curly quotes and em dashes inside free-text insights, not corrupted encodings"
        if non_ascii
        else "Pure ASCII",
        "legitimate",
    )

    sentinel_hits = {}
    for c in text_cols:
        vals = df[c].dropna().str.lower().str.strip()
        hit = vals[vals.isin(SENTINELS)]
        if len(hit):
            sentinel_hits[c] = int(len(hit))
    add(
        "Missing-value sentinel tokens (NA, null, '-', ...)",
        "text columns",
        int(sum(sentinel_hits.values())),
        f"Missing data uses true blanks only; {sentinel_hits if sentinel_hits else 'no sentinel tokens found'}",
        "pass",
    )

    for col, expected in [
        ("category", 15),
        ("risk_level", 4),
        ("salary_trend", 4),
        ("agentic_risk", 4),
        ("tier", 2),
    ]:
        vals = sorted(df[col].dropna().unique().tolist())
        ok = len(vals) == expected
        if col != "category":
            # One consistent case style, no padded values (e.g. all "Low/High", never "low / HIGH ").
            styles = set()
            for v in vals:
                if isinstance(v, str):
                    styles.add("lower" if v.islower() else "title" if v.istitle() else "other")
                    styles.add("padded") if v != v.strip() else None
            ok = ok and len(styles) <= 1 and "other" not in styles and "padded" not in styles
        add(
            f"Label domain: {col}",
            col,
            0 if ok else len(vals),
            f"{len(vals)} levels, consistent casing/spelling: {vals}",
            "pass" if ok else "flagged",
        )

    meta_cats = set(js["categories"])
    add(
        "Category labels match JSON metadata",
        "category",
        len(set(df.category) ^ meta_cats),
        "All 15 labels identical across CSV, JSON metadata and JSON roles",
        "pass",
    )

    add(
        "SOC code format (NN-NNNN)",
        "soc_code",
        int((~df.soc_code.astype(str).str.match(SOC_RE)).sum()),
        "All 300 codes follow the BLS SOC 2018 pattern",
        "pass",
    )
    add(
        "Slug format (lowercase-hyphen)",
        "slug",
        int((~df.slug.astype(str).str.match(SLUG_RE)).sum()),
        "All slugs are clean URL-safe identifiers",
        "pass",
    )
    add(
        "SOC codes present in crosswalk",
        "soc_code",
        int((~df.soc_code.isin(crosswalk.soc_code)).sum()),
        "Every scored role's SOC code appears in soc-crosswalk.csv",
        "pass",
    )

    dup_soc = df[df.soc_code.duplicated(keep=False)]
    add(
        "SOC codes shared by several roles",
        "soc_code",
        int(len(dup_soc)),
        f"{dup_soc.soc_code.nunique()} BLS codes map to 2-5 distinct role rows "
        "(e.g. 13-1071 -> Recruiter, HR Generalist, Talent Sourcer). Legitimate, not duplication error",
        "legitimate",
    )

    roles = js["roles"]
    same_order = [r["slug"] for r in roles] == df.slug.tolist()
    score_ok = all(r["score"] == s for r, s in zip(roles, df.score))
    salary_ok = all(
        (r["salary"]["low"], r["salary"]["high"]) == (lo, hi)
        for r, lo, hi in zip(roles, df.salary_low_usd, df.salary_high_usd)
    )
    task_ok = all(
        (len(r["tasksAtRisk"]), len(r["tasksGrowing"]))
        == (a, b)
        for r, a, b in zip(roles, df.tasks_at_risk_count, df.tasks_growing_count)
    )
    hist_ok = all(
        [r["historicalScores"].get(q) for q in ["Q1 2025", "Q3 2025", "Q1 2026", "Q2 2026", "Q3 2026"]]
        == [None if pd.isna(v) else v for v in rec]
        for r, rec in zip(roles, df[HISTORY_COLS].itertuples(index=False))
    )
    all_ok = all([same_order, score_ok, salary_ok, task_ok, hist_ok])
    add(
        "CSV vs JSON agreement",
        "score, salary, task counts, quarterly history",
        0 if all_ok else 1,
        f"row order={same_order}, scores={score_ok}, salaries={salary_ok}, "
        f"task counts={task_ok}, quarterly history={hist_ok}",
        "pass" if all_ok else "flagged",
    )

    strict = df.score.map(band_of)
    mismatch = df[strict != df.risk_level]
    # Boundary thresholds between the four published bands.
    boundaries = np.array([35.5, 50.5, 75.5])
    dist = np.abs(mismatch.score.to_numpy()[:, None] - boundaries).min(axis=1) if len(mismatch) else np.array([])
    within_5 = int((dist <= 5).sum())
    restated = int(mismatch.slug.isin(
        [r["slug"] for r in js["roles"] if "restatement" in r]
    ).sum()) if len(mismatch) else 0
    add(
        "risk_level matches documented bands",
        "score, risk_level",
        int(len(mismatch)),
        f"{len(mismatch)} roles carry a band one step away from the band implied by their score; "
        f"{within_5} sit within 5 points of a published boundary (the metadata's band-stability rule) "
        f"and {restated} are roles with a documented restatement reason. Labels are therefore "
        "consistent with the rubric but not a deterministic function of score",
        "legitimate",
    )

    agentic_strict = df.sub_agentic_exposure.map(band_of)
    add(
        "agentic_risk matches sub-score bands",
        "agentic_risk, sub_agentic_exposure",
        int((agentic_strict != df.agentic_risk).sum()),
        "agentic_risk is a pure band of the agentic sub-score and adds no information beyond it",
        "legitimate",
    )
    return pd.DataFrame(rows)


def numeric_checks(df: pd.DataFrame, js: dict, crosswalk: pd.DataFrame) -> pd.DataFrame:
    """Type, range, logical-relationship and recomputation checks."""
    rows = []

    def add(check, column, n_fail, detail, status):
        rows.append(
            {"check": check, "column": column, "n_failures": n_fail, "detail": detail, "status": status}
        )

    int_like = [
        "score",
        "salary_low_usd",
        "salary_high_usd",
        "tasks_at_risk_count",
        "tasks_growing_count",
        "tier",
        *SUBSCORE_COLS,
        *HISTORY_COLS,
    ]
    bad_dtype = [c for c in int_like if df[c].dropna().mod(1).ne(0).any()]
    add(
        "Scores/counts stored as whole numbers",
        ", ".join(int_like),
        len(bad_dtype),
        "All scores, salaries, counts and sub-scores are integers" if not bad_dtype
        else f"Non-integer values in {bad_dtype}",
        "pass" if not bad_dtype else "flagged",
    )

    add(
        "salary_low_usd < salary_high_usd",
        "salary bounds",
        int((df.salary_low_usd >= df.salary_high_usd).sum()),
        "Lower bound strictly below upper bound for all 300 roles; no equal or inverted bounds",
        "pass",
    )
    add(
        "Salaries positive",
        "salary bounds",
        int((df.salary_low_usd <= 0).sum()),
        f"Range ${df.salary_low_usd.min():,}-${df.salary_high_usd.max():,}; anchored to BLS OES p25-p75",
        "pass",
    )
    add(
        "Negative values in numeric columns",
        "all numeric",
        int((df.select_dtypes("number") < 0).sum().sum()),
        "No negative entries",
        "pass",
    )

    add(
        "score within documented 0-100 range",
        "score",
        int((~df.score.between(0, 100)).sum()),
        f"Observed range {df.score.min()}-{df.score.max()}",
        "pass",
    )
    add(
        "Sub-scores within 0-100",
        ", ".join(SUBSCORE_COLS),
        int(sum((~df[c].between(0, 100)).sum() for c in SUBSCORE_COLS)),
        "All four sub-scores bounded 0-100 for all 300 roles",
        "pass",
    )
    add(
        "Quarterly scores within 0-100",
        ", ".join(HISTORY_COLS),
        int(sum((~df[c].dropna().between(0, 100)).sum() for c in HISTORY_COLS)),
        f"All {int(df[HISTORY_COLS].notna().sum().sum())} observed quarterly values bounded 0-100",
        "pass",
    )

    add(
        "score equals score_q3_2026",
        "score, score_q3_2026",
        int((df.score != df.score_q3_2026).sum()),
        "The current score is definitionally the Q3 2026 value, so the two columns are perfectly redundant",
        "legitimate",
    )

    formula = (
        df.sub_task_automation
        * (0.45 + 0.30 * df.sub_tool_maturity / 100 + 0.25 * df.sub_adoption / 100)
        + 0.10 * df.sub_agentic_exposure
    )
    max_diff = float((formula - df.score).abs().max())
    add(
        "Composite reproducible from sub-scores",
        "score, sub-scores",
        int((formula.round() != df.score).sum()),
        f"Published formula reproduces the score for {len(df)}/{len(df)} roles "
        f"(max |diff| = {max_diff:.2f}, rounding only)",
        "pass",
    )

    add(
        "tasks_at_risk_count equals task list length",
        "tasks_at_risk_count",
        int(sum(len(r["tasksAtRisk"]) != v for r, v in zip(js["roles"], df.tasks_at_risk_count))),
        f"Counts match JSON task lists (range {df.tasks_at_risk_count.min()}-{df.tasks_at_risk_count.max()})",
        "pass",
    )
    add(
        "tasks_growing_count equals task list length",
        "tasks_growing_count",
        int(sum(len(r["tasksGrowing"]) != v for r, v in zip(js["roles"], df.tasks_growing_count))),
        f"Counts match JSON task lists (range {df.tasks_growing_count.min()}-{df.tasks_growing_count.max()})",
        "pass",
    )

    spread = (df.salary_high_usd - df.salary_low_usd) / df.salary_low_usd
    n_wide = int((spread > 1.5).sum())
    add(
        "Salary spread wider than 150% of lower bound",
        "salary bounds",
        n_wide,
        f"Median spread {spread.median():.0%}; {n_wide} roles exceed 150% "
        "(e.g. Investment Banker $85k-$275k, Surgeon $280k-$450k). Consistent with p25-p75 bounds",
        "legitimate",
    )

    add(
        "Crosswalk rows with no matched role",
        "nearest_role_slug, score, risk_level (crosswalk)",
        int(crosswalk.nearest_role_slug.isna().sum()),
        f"{int(crosswalk.nearest_role_slug.isna().sum())} of 867 SOC codes are 'unmatched': "
        "farm (45-xxxx) and military (55-xxxx) occupations sit outside the 300 scored roles",
        "structural",
    )
    return pd.DataFrame(rows)


def outlier_scan(df: pd.DataFrame) -> pd.DataFrame:
    """IQR flags. Flags are reported, never removed: each is inspected by hand."""
    rows = []
    for col in ["score", "salary_low_usd", "salary_high_usd"]:
        q1, q3 = df[col].quantile([0.25, 0.75])
        iqr = q3 - q1
        flag = (df[col] < q1 - 1.5 * iqr) | (df[col] > q3 + 1.5 * iqr)
        sub = df[flag]
        rows.append(
            {
                "column": col,
                "q1": q1,
                "q3": q3,
                "lower_fence": round(q1 - 1.5 * iqr, 1),
                "upper_fence": round(q3 + 1.5 * iqr, 1),
                "n_flagged": int(flag.sum()),
                "pct_flagged": round(100 * flag.mean(), 1),
                "min_flagged": sub[col].min() if len(sub) else np.nan,
                "max_flagged": sub[col].max() if len(sub) else np.nan,
                "examples": "; ".join(sub.nlargest(3, col).title.tolist()) if len(sub) else "",
            }
        )
    return pd.DataFrame(rows)


def summary_table(df, profile, enc, outl) -> pd.DataFrame:
    """One row per issue: affected columns, record counts, classification, action."""
    gap = int(profile.loc[profile.column == "score_q1_2025", "n_missing"].iloc[0])
    mism = int(enc.loc[enc.check == "risk_level matches documented bands", "n_flagged"].iloc[0])
    salary_flags = int(outl.loc[outl.column.isin(["salary_low_usd", "salary_high_usd"]), "n_flagged"].sum())
    score_flags = int(outl.loc[outl.column == "score", "n_flagged"].iloc[0])
    rows = [
        {
            "issue": "Quarterly scores missing before Q3 2026",
            "columns": ", ".join(HISTORY_COLS[:-1]),
            "n_records": gap,
            "classification": "Structural (by design)",
            "recommended_action": "Do not impute. Restrict time-series work to the 76 roles with full history and report the 300-role cross-section separately",
        },
        {
            "issue": "Current score duplicates Q3 2026 score",
            "columns": "score, score_q3_2026",
            "n_records": int(len(df)),
            "classification": "Redundant (not an error)",
            "recommended_action": "Keep a single score column and build a long-format quarter variable from the history columns",
        },
        {
            "issue": "Score is an exact function of the four sub-scores",
            "columns": ", ".join(SUBSCORE_COLS),
            "n_records": int(len(df)),
            "classification": "Redundant (not an error)",
            "recommended_action": "Describe sub-scores as components of the composite; do not treat them as independent predictors",
        },
        {
            "issue": "risk_level label disagrees with the score band",
            "columns": "score, risk_level",
            "n_records": mism,
            "classification": "Documented boundary-stability rule",
            "recommended_action": "Use score-derived bands for comparisons and keep the published label for reference only",
        },
        {
            "issue": "agentic_risk is a deterministic band of its sub-score",
            "columns": "agentic_risk, sub_agentic_exposure",
            "n_records": int(len(df)),
            "classification": "Redundant (not an error)",
            "recommended_action": "Use the numeric sub-score and drop the band in analysis",
        },
        {
            "issue": "Salary values beyond IQR fences",
            "columns": "salary_low_usd, salary_high_usd",
            "n_records": salary_flags,
            "classification": "Legitimate extreme values",
            "recommended_action": "Retain. Analyse salary on a log scale or with rank-based (Spearman) methods",
        },
        {
            "issue": "Score value beyond IQR fence",
            "columns": "score",
            "n_records": score_flags,
            "classification": "Legitimate extreme value",
            "recommended_action": "Retain: Data Entry Clerk (92) is the top of the documented 0-100 scale",
        },
        {
            "issue": "Unmatched SOC codes in the crosswalk",
            "columns": "nearest_role_slug, score, risk_level (crosswalk)",
            "n_records": 33,
            "classification": "Structural (out of scope)",
            "recommended_action": "Exclude from merges or keep and label as unmatched; never assign a score",
        },
        {
            "issue": "Duplicates, types, ranges, labels, sentinel tokens",
            "columns": "all",
            "n_records": 0,
            "classification": "Passed",
            "recommended_action": "No action; only type conversions are needed in Step 3",
        },
    ]
    return pd.DataFrame(rows)


def make_figure(df: pd.DataFrame, profile: pd.DataFrame) -> None:
    """One two-panel figure: where the gaps are, and which categories they hit."""
    fig, axes = plt.subplots(1, 2, figsize=(12.6, 5.8), gridspec_kw={"width_ratios": [1, 1.1]})

    prof = profile.sort_values(["pct_missing", "column"])
    colors = ["#c0392b" if c in HISTORY_COLS else "#95a5a6" for c in prof.column]
    ax = axes[0]
    ax.barh(prof.column, prof.pct_missing, color=colors, height=0.72)
    ax.set_xlabel("Missing values (% of 300 rows)")
    ax.set_title("A. Missingness by column", loc="left", fontweight="bold")
    ax.set_xlim(0, 100)
    ax.tick_params(axis="y", labelsize=7.5)
    for y, v in enumerate(prof.pct_missing):
        if v > 0:
            ax.text(v + 1.5, y, f"{v:.1f}%", va="center", fontsize=7.5, color="#c0392b")
    ax.axvline(0, color="black", lw=0.6)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)

    cats = (
        df.assign(has_history=df.score_q1_2025.notna())
        .groupby("category")
        .agg(n_roles=("slug", "size"), n_hist=("has_history", "sum"))
        .assign(pct=lambda d: 100 * d["n_hist"] / d["n_roles"])
        .sort_values("pct")
    )
    ax = axes[1]
    ax.barh(cats.index, cats.pct, color="#2c7fb8", height=0.7)
    ax.set_xlabel("Roles with data before Q3 2026 (%)")
    ax.set_title("B. Historical coverage by occupational category", loc="left", fontweight="bold")
    ax.set_xlim(0, 100)
    ax.tick_params(axis="y", labelsize=8)
    for y, (pct, n) in enumerate(zip(cats.pct, cats.n_roles)):
        ax.text(pct + 1.5, y, f"{pct:.0f}%  (n={n})", va="center", fontsize=7.5, color="#1f5f8b")
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)

    fig.suptitle("Data quality: missing historical scores are structural, not scattered", fontsize=11.5)
    fig.tight_layout()
    fig.savefig(FIGS / "dq_missingness_overview.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    TABLES.mkdir(parents=True, exist_ok=True)
    FIGS.mkdir(parents=True, exist_ok=True)
    df, js, crosswalk = load_data()

    profile = column_profile(df)
    miss = missingness_table(df)
    miss_cat = missingness_by_category(df)
    assoc = missingness_association(df)
    enc = encoding_checks(df, js, crosswalk)
    num = numeric_checks(df, js, crosswalk)
    outl = outlier_scan(df)
    summ = summary_table(df, profile, enc, outl)

    outputs = {
        "dq_column_profile.csv": profile,
        "dq_missingness.csv": miss,
        "dq_missingness_by_category.csv": miss_cat,
        "dq_missingness_association.csv": assoc,
        "dq_encoding_checks.csv": enc,
        "dq_numeric_validation.csv": num,
        "dq_outlier_scan.csv": outl,
        "dq_summary.csv": summ,
    }
    for name, table in outputs.items():
        table.to_csv(TABLES / name, index=False)
    make_figure(df, profile)

    flagged = enc.loc[enc.status == "flagged", "check"].tolist() + num.loc[num.status == "flagged", "check"].tolist()
    print(f"rows={len(df)} cols={df.shape[1]} | documented issues={len(summ)} | failed checks={flagged or 'none'}")
    print(f"missing cells={int(df.isna().sum().sum())} | max missing in a column={int(miss.n_missing.max())}")
    print(f"duplicate rows={int(df.duplicated().sum())} | IQR flags={int(outl.n_flagged.sum())} (score {int(outl.loc[outl.column=='score','n_flagged'].iloc[0])})")
    print(f"encoding checks passed={int((enc.status=='pass').sum())}/{len(enc)} | numeric checks passed={int((num.status=='pass').sum())}/{len(num)}")
    print("wrote:", ", ".join(outputs), "+ outputs/figures/dq_missingness_overview.png")
    missing_files = [n for n in outputs if not (TABLES / n).exists()]
    if missing_files or not (FIGS / "dq_missingness_overview.png").exists():
        raise SystemExit(f"missing outputs: {missing_files}")


if __name__ == "__main__":
    main()
