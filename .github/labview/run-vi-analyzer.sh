#!/usr/bin/env bash
# =============================================================================
# run-vi-analyzer.sh — Runs LabVIEW VI Analyzer in a Linux container
# =============================================================================
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/run-vi-analyzer.sh \
#       /workspace                          # WorkspaceRoot
#       /report                             # ReportDir
# =============================================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-/workspace}"
REPORT_DIR="${2:-/report}"
DEFAULT_TEMPLATE="${WORKSPACE_ROOT}/.github/labview/via-configs/via-config-default.viancfg"

# config.viAnalyzer support (Linux honors the DEFAULT config + the single-VI
# re-run; per-subset RULES are a Windows-only feature, so Linux analyzes the whole
# workspace with the default). These are set by the workflow.
VIA_FILES="${VIA_FILES:-}"      # pipe-delimited repo-relative VIs (single-VI re-run)
VIA_CONFIG="${VIA_CONFIG:-}"    # .viancfg to use for the re-run
VIA_DEFAULT="${VIA_DEFAULT:-}"  # builtin | none | <.viancfg> (full-run default)

# When no default was passed, read config.viAnalyzer.default from the manifest
# (same flat format the Configure dialog writes); the resolver below auto-detects
# the first committed .viancfg if it is still empty.
MANIFEST="${WORKSPACE_ROOT}/.github/labview-ci.yml"
if [ -z "$VIA_DEFAULT" ] && [ -z "$VIA_FILES" ] && [ -f "$MANIFEST" ]; then
  VIA_DEFAULT=$(awk '
    /^  viAnalyzer:[[:space:]]*$/ {inv=1; next}
    inv && /^    default:[[:space:]]*/ {sub(/^    default:[[:space:]]*/,""); gsub(/"/,""); gsub(/[[:space:]]/,""); print; exit}
    inv && /^  [^[:space:]]/ {inv=0}
    inv && /^[^[:space:]]/ {inv=0}
  ' "$MANIFEST")
fi

# LabVIEWCLI is on PATH in the NI Linux container
LABVIEWCLI="LabVIEWCLI"
# Discover labviewprofull dynamically (year varies by image tag)
LABVIEW_EXE=$(find /usr/local/natinst -name "labviewprofull" 2>/dev/null | head -1)
if [ -z "$LABVIEW_EXE" ]; then echo "ERROR: labviewprofull not found in /usr/local/natinst" >&2; exit 1; fi
echo "Using LabVIEW: $LABVIEW_EXE"

mkdir -p "$REPORT_DIR"

CONFIG_FILE="$REPORT_DIR/via-config.viancfg"
RESULTS_XML="$REPORT_DIR/via-results.xml"
HTML_OUT="$REPORT_DIR/index.html"

# Rewrite a .viancfg's <ItemsToAnalyze> block to a given set of absolute paths so a
# config's TEST settings apply to a chosen scope (whole workspace, or the re-run's VIs).
rewrite_items() {
  local cfg="$1"; shift
  local items_file="$REPORT_DIR/.via-items.xml"
  {
    printf '\t<ItemsToAnalyze>\n'
    local p
    for p in "$@"; do
      printf '\t\t<Item>\n\t\t\t<Path>"%s"</Path>\n\t\t\t<Removed>FALSE</Removed>\n\t\t</Item>\n' "$p"
    done
    printf '\t</ItemsToAnalyze>\n'
  } > "$items_file"
  awk -v items_file="$items_file" '
    /<ItemsToAnalyze>/ {
      while ((getline line < items_file) > 0) print line
      close(items_file)
      if ($0 ~ /<\/ItemsToAnalyze>/) { next }   # single-line block, fully replaced
      skip = 1; next
    }
    skip && /<\/ItemsToAnalyze>/ { skip = 0; next }
    skip { next }
    { print }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
}

# Resolve which .viancfg drives this run and whether to inject the full built-in
# test suite (only when using the bundled default template).
USE_BUILTIN_SUITE=0
declare -a ITEM_PATHS=()
if [ -n "$VIA_FILES" ]; then
  if [ -z "$VIA_CONFIG" ]; then echo "ERROR: VIA_FILES set without VIA_CONFIG" >&2; exit 1; fi
  CONFIG_SRC="${WORKSPACE_ROOT}/${VIA_CONFIG}"
  IFS='|' read -r -a _via_files <<< "$VIA_FILES"
  for f in "${_via_files[@]}"; do [ -n "$f" ] && ITEM_PATHS+=("${WORKSPACE_ROOT}/${f}"); done
  RUN_MODE="single-VI re-run with ${VIA_CONFIG}"
else
  DEF="$VIA_DEFAULT"
  if [ -z "$DEF" ]; then
    DEF_REL=$(find "$WORKSPACE_ROOT" -type f -name '*.viancfg' 2>/dev/null | grep -Ev '/(\.github|ci-out|build)/' | sed "s|^${WORKSPACE_ROOT}/||" | sort | head -1)
    if [ -n "$DEF_REL" ]; then DEF="$DEF_REL"; echo "Auto-detected default config: $DEF_REL"; fi
  fi
  # Linux ignores per-subset rules; default=none with no rules means "test nothing",
  # but to avoid an empty/failed run we fall back to the built-in suite here.
  if [ -z "$DEF" ] || [ "$DEF" = "builtin" ] || [ "$DEF" = "none" ]; then
    CONFIG_SRC="$DEFAULT_TEMPLATE"; USE_BUILTIN_SUITE=1; ITEM_PATHS=("$WORKSPACE_ROOT")
    RUN_MODE="full built-in suite"
  else
    CONFIG_SRC="${WORKSPACE_ROOT}/${DEF}"; ITEM_PATHS=("$WORKSPACE_ROOT")
    RUN_MODE="default config ${DEF}"
  fi
fi

echo "=== VI Analyzer (Linux) ==="
echo "  Workspace  : $WORKSPACE_ROOT"
echo "  Mode       : $RUN_MODE"
echo "  Config src : $CONFIG_SRC"

# Patch __WORKSPACE_PATH__ placeholder, then scope <ItemsToAnalyze> to ITEM_PATHS.
sed "s|__WORKSPACE_PATH__|${WORKSPACE_ROOT}|g" "$CONFIG_SRC" > "$CONFIG_FILE"
rewrite_items "$CONFIG_FILE" "${ITEM_PATHS[@]}"

# Build TestConfigData from installed VI Analyzer test LLBs so Linux runs the full
# suite -- only for the bundled default template (a user .viancfg carries its own tests).
LABVIEW_ROOT="$(dirname "$LABVIEW_EXE")"
TEST_ROOT="$LABVIEW_ROOT/resource/dialog/VI Analyzer/tests"
TEST_ENTRIES_FILE="$REPORT_DIR/via-tests.xml"
TEST_COUNT=0

if [ "$USE_BUILTIN_SUITE" = "1" ] && [ -d "$TEST_ROOT" ]; then
  : > "$TEST_ENTRIES_FILE"
  while IFS= read -r llb; do
    rel_path="${llb#${LABVIEW_ROOT}/}"
    test_name="$(basename "$llb" .llb)"
    cat >> "$TEST_ENTRIES_FILE" <<EOF
		<Test>
			<Name>"$test_name"</Name>
			<Ranking>1</Ranking>
			<MaxFailures>5</MaxFailures>
			<BasePath>"$LABVIEW_ROOT"</BasePath>
			<RelativePath>"$rel_path"</RelativePath>
			<Selected>TRUE</Selected>
			<Controls>
			</Controls>
		</Test>
EOF
    TEST_COUNT=$((TEST_COUNT+1))
  done < <(find "$TEST_ROOT" -type f -name '*.llb' | sort)

  if [ "$TEST_COUNT" -gt 0 ]; then
    awk -v tests_file="$TEST_ENTRIES_FILE" '
      /<TestConfigData>/ {
        print
        while ((getline line < tests_file) > 0) print line
        close(tests_file)
        next
      }
      { print }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  fi
fi

echo "  Config out : $CONFIG_FILE"
echo "  VIA tests  : $TEST_COUNT discovered at $TEST_ROOT"

START=$(date +%s)

"$LABVIEWCLI" \
    -OperationName RunVIAnalyzer \
    -LabVIEWPath "$LABVIEW_EXE" \
    -ConfigPath "$CONFIG_FILE" \
    -ReportPath "$RESULTS_XML" \
    -Headless || EXIT_CODE=$?

EXIT_CODE="${EXIT_CODE:-0}"
END=$(date +%s)
DURATION=$(( END - START ))

echo ""
echo "=== VI Analyzer finished (exit=$EXIT_CODE duration=${DURATION}s) ==="

# Generate minimal HTML wrapper around the XML results
XML_CONTENT="$(cat "$RESULTS_XML" 2>/dev/null || echo '(no results file)')"
# Escape for HTML
XML_HTML="$(echo "$XML_CONTENT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
REPORT_TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="PASSED"; BADGE_COLOR="#2ea043"
else
    STATUS="FAILED"; BADGE_COLOR="#da3633"
fi

cat > "$HTML_OUT" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VI Analyzer — Extensible-Config-Dialog</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;padding:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
    .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:${BADGE_COLOR}}
    .meta{margin-top:10px;font-size:.82em;color:#8b949e}
    pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;overflow-y:auto;max-height:65vh;margin:0}
  </style>
</head>
<body>
  <div class="card">
    <h1>VI Analyzer — Extensible-Config-Dialog</h1>
    <span class="badge">${STATUS}</span>
    <div class="meta">Date: ${REPORT_TS} &nbsp;|&nbsp; Duration: ${DURATION}s</div>
  </div>
  <pre>${XML_HTML}</pre>
</body>
</html>
HTML

echo "HTML report → $HTML_OUT"
exit "$EXIT_CODE"
