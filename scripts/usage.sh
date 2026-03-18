#!/usr/bin/env bash
# =============================================================================
# usage.sh — Query Anthropic Admin API for token usage reports
# =============================================================================
# Usage:
#   bash scripts/usage.sh [--daily] [--weekly] [--monthly] [--breakdown]
#
# Flags can be combined, e.g.:
#   bash scripts/usage.sh --weekly --breakdown
#
# Requirements: curl, jq
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

# Path to the file that holds your Anthropic Admin API key.
# We read from a file instead of an environment variable so the key never
# appears in your shell history, process list, or shell profile.
KEY_FILE="${HOME}/.config/anthropic-usage/api_key"

# Anthropic API endpoint for usage reports.
API_BASE="https://api.anthropic.com/v1/organizations/usage_report/messages"

# The API version header required by Anthropic.
API_VERSION="2023-06-01"

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

# Print an error message to stderr and exit with a non-zero status.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Print usage/help text.
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Query the Anthropic Admin API for token usage reports.

Options:
  --daily       Show today's usage
  --weekly      Show the past 7 days of usage (default)
  --monthly     Show the past 30 days of usage
  --breakdown   Group results by model
  --help        Show this help message

Examples:
  $(basename "$0") --daily
  $(basename "$0") --weekly --breakdown
  $(basename "$0") --monthly --breakdown
EOF
}

# Check that a required command is available on PATH.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Please install it and retry."
}

# -----------------------------------------------------------------------------
# DATE UTILITIES (GNU/BSD compatible)
# -----------------------------------------------------------------------------
# Linux ships with GNU coreutils; macOS ships with BSD date.
# Their flags for date arithmetic are different, so we detect which one we have.

# Returns an RFC3339 timestamp (e.g. 2024-03-01T00:00:00Z) for N days ago.
# Usage: date_n_days_ago <N>
date_n_days_ago() {
  local n="$1"
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    date -u -d "${n} days ago" '+%Y-%m-%dT00:00:00Z'
  else
    # BSD date (macOS)
    date -u -v"-${n}d" '+%Y-%m-%dT00:00:00Z'
  fi
}

# Returns today's date as an RFC3339 timestamp at midnight UTC.
today_utc() {
  date -u '+%Y-%m-%dT00:00:00Z'
}

# Returns tomorrow's date (exclusive end of today's range) in RFC3339.
tomorrow_utc() {
  if date --version >/dev/null 2>&1; then
    # GNU date
    date -u -d "tomorrow" '+%Y-%m-%dT00:00:00Z'
  else
    # BSD date
    date -u -v+1d '+%Y-%m-%dT00:00:00Z'
  fi
}

# -----------------------------------------------------------------------------
# NUMBER FORMATTING
# -----------------------------------------------------------------------------

# Add comma separators to a number (e.g. 1234567 → 1,234,567).
# Uses awk for portability (no LC_ALL tricks needed).
format_number() {
  echo "$1" | awk '{ printf "%'"'"'d\n", $1 }'
}

# -----------------------------------------------------------------------------
# API CALL
# -----------------------------------------------------------------------------

# Call the Anthropic usage API and return the raw JSON response.
# Arguments:
#   $1 — starting_at (RFC3339)
#   $2 — ending_at   (RFC3339)
#   $3 — group_by    ("model" or "" for no grouping)
fetch_usage() {
  local starting_at="$1"
  local ending_at="$2"
  local group_by="$3"

  # Build the query string. We always use a 1-day bucket so we get
  # per-day granularity; the caller sums them up if needed.
  local query="starting_at=${starting_at}&ending_at=${ending_at}&bucket_width=1d"

  # Append model grouping if requested.
  if [[ -n "$group_by" ]]; then
    query="${query}&group_by%5B%5D=${group_by}"
  fi

  local url="${API_BASE}?${query}"

  # Make the API call. -s = silent (no progress bar), -f = fail on HTTP errors.
  # We capture stderr separately so we can give a better error message.
  local response
  local http_code

  # Use -w to capture the HTTP status code as the last line of output.
  response=$(curl -s -w "\n%{http_code}" \
    -H "x-api-key: ${ANTHROPIC_ADMIN_API_KEY}" \
    -H "anthropic-version: ${API_VERSION}" \
    -H "Content-Type: application/json" \
    "${url}") || die "Network error: curl failed. Check your internet connection."

  # Split response body and HTTP status code.
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | head -n -1)

  # Handle HTTP errors with user-friendly messages.
  case "$http_code" in
    200)
      echo "$body"
      ;;
    401)
      die "401 Unauthorized — your API key is invalid or has been revoked. Check ~/.config/anthropic-usage/api_key."
      ;;
    403)
      die "403 Forbidden — your key lacks Admin permissions, or your account is not on an Anthropic Organization plan. Usage reports require an Organization account."
      ;;
    404)
      die "404 Not Found — the usage report endpoint was not found. The API URL may have changed; please check for an updated version of this script."
      ;;
    429)
      die "429 Too Many Requests — you are being rate-limited. Wait a moment and try again."
      ;;
    5*)
      die "Server error (HTTP ${http_code}) — the Anthropic API returned an unexpected error. Try again in a few minutes."
      ;;
    *)
      die "Unexpected HTTP status ${http_code}. Response: ${body}"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# RENDERING
# -----------------------------------------------------------------------------

# Print a markdown-friendly table of aggregated usage (no model breakdown).
# Reads JSON from stdin.
render_summary() {
  local label="$1"
  local json="$2"

  # Sum up all buckets using jq.
  local total_input total_output total_requests
  total_input=$(echo "$json" | jq '[.data[].metrics.input_tokens // 0] | add // 0')
  total_output=$(echo "$json" | jq '[.data[].metrics.output_tokens // 0] | add // 0')
  total_requests=$(echo "$json" | jq '[.data[].metrics.request_count // 0] | add // 0')

  echo ""
  echo "## ${label}"
  echo ""
  echo "| Metric          | Value                        |"
  echo "|-----------------|------------------------------|"
  printf "| Input tokens    | %-28s |\n" "$(format_number "$total_input")"
  printf "| Output tokens   | %-28s |\n" "$(format_number "$total_output")"
  printf "| Total tokens    | %-28s |\n" "$(format_number "$((total_input + total_output))")"
  printf "| Requests        | %-28s |\n" "$(format_number "$total_requests")"
  echo ""
}

# Print a markdown-friendly table broken down by model.
# Reads JSON from stdin.
render_breakdown() {
  local label="$1"
  local json="$2"

  echo ""
  echo "## ${label} — by model"
  echo ""
  echo "| Model | Input tokens | Output tokens | Requests |"
  echo "|-------|-------------|---------------|----------|"

  # Use jq to aggregate per model across all time buckets, then render each row.
  echo "$json" | jq -r '
    # Build a map: model → {input, output, requests}
    reduce .data[] as $bucket (
      {};
      ($bucket.group_by.model // "unknown") as $model |
      .[$model].input   += ($bucket.metrics.input_tokens   // 0) |
      .[$model].output  += ($bucket.metrics.output_tokens  // 0) |
      .[$model].reqs    += ($bucket.metrics.request_count  // 0)
    )
    | to_entries
    | sort_by(-.value.input)   # Sort by input tokens descending (highest usage first)
    | .[]
    | [.key, .value.input, .value.output, .value.reqs]
    | @tsv
  ' | while IFS=$'\t' read -r model input output reqs; do
      printf "| %-40s | %13s | %13s | %8s |\n" \
        "$model" \
        "$(format_number "$input")" \
        "$(format_number "$output")" \
        "$(format_number "$reqs")"
    done

  echo ""
}

# -----------------------------------------------------------------------------
# ARGUMENT PARSING
# -----------------------------------------------------------------------------

OPT_DAILY=false
OPT_WEEKLY=false
OPT_MONTHLY=false
OPT_BREAKDOWN=false

# If no arguments are given, default to --weekly.
if [[ $# -eq 0 ]]; then
  OPT_WEEKLY=true
fi

for arg in "$@"; do
  case "$arg" in
    --daily)     OPT_DAILY=true ;;
    --weekly)    OPT_WEEKLY=true ;;
    --monthly)   OPT_MONTHLY=true ;;
    --breakdown) OPT_BREAKDOWN=true ;;
    --help|-h)   usage; exit 0 ;;
    *)           die "Unknown option: ${arg}. Run with --help to see available options." ;;
  esac
done

# If none of daily/weekly/monthly was selected, default to weekly.
if ! $OPT_DAILY && ! $OPT_WEEKLY && ! $OPT_MONTHLY; then
  OPT_WEEKLY=true
fi

# -----------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# -----------------------------------------------------------------------------

require_cmd curl
require_cmd jq

# Ensure the key file exists.
if [[ ! -f "$KEY_FILE" ]]; then
  die "API key file not found: ${KEY_FILE}

  Please set up your API key first:
    mkdir -p ~/.config/anthropic-usage
    chmod 700 ~/.config/anthropic-usage
    printf '%s' 'YOUR_API_KEY_HERE' > ~/.config/anthropic-usage/api_key
    chmod 600 ~/.config/anthropic-usage/api_key

  See README.md for full setup instructions."
fi

# Read the key from the file. tr -d removes any accidental trailing newline.
ANTHROPIC_ADMIN_API_KEY=$(tr -d '[:space:]' < "$KEY_FILE")

# Basic sanity check — Anthropic Admin keys start with "sk-ant-admin".
if [[ -z "$ANTHROPIC_ADMIN_API_KEY" ]]; then
  die "API key file is empty: ${KEY_FILE}"
fi

# -----------------------------------------------------------------------------
# GROUP_BY FLAG
# -----------------------------------------------------------------------------

# If --breakdown was requested, we pass group_by=model to the API.
GROUP_BY=""
if $OPT_BREAKDOWN; then
  GROUP_BY="model"
fi

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

echo "Querying Anthropic usage API..."

# ---- Daily ------------------------------------------------------------------
if $OPT_DAILY; then
  START=$(today_utc)
  END=$(tomorrow_utc)
  JSON=$(fetch_usage "$START" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Today's usage ($(date -u '+%Y-%m-%d'))" "$JSON"
  else
    render_summary "Today's usage ($(date -u '+%Y-%m-%d'))" "$JSON"
  fi
fi

# ---- Weekly -----------------------------------------------------------------
if $OPT_WEEKLY; then
  START=$(date_n_days_ago 7)
  END=$(tomorrow_utc)
  JSON=$(fetch_usage "$START" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Usage — past 7 days" "$JSON"
  else
    render_summary "Usage — past 7 days" "$JSON"
  fi
fi

# ---- Monthly ----------------------------------------------------------------
if $OPT_MONTHLY; then
  START=$(date_n_days_ago 30)
  END=$(tomorrow_utc)
  JSON=$(fetch_usage "$START" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Usage — past 30 days" "$JSON"
  else
    render_summary "Usage — past 30 days" "$JSON"
  fi
fi

echo "Done."
