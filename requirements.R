# R dependencies for the AI Career Threat Index project.
# Install once per machine:  Rscript requirements.R
# Then run the analysis with: Rscript src/data_quality.R

pkgs <- c("readr", "dplyr", "jsonlite", "ggplot2", "patchwork")

missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  install.packages(missing, repos = "https://cloud.r-project.org")
}

versions <- vapply(pkgs, function(p) as.character(packageVersion(p)), character(1))
cat(sprintf("%-10s %s\n", pkgs, versions), sep = "")
cat("R version:", R.version.string, "\n")
