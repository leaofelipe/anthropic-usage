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

# Make a single HTTP request to the Anthropic usage API.
# Prints the parsed response body to stdout and returns the HTTP status code
# via the global variable _HTTP_CODE.
# Arguments:
#   $1 — full URL (including query string)
_curl_usage() {
  local url="$1"
  local response http_code body

  # --connect-timeout: abort if TCP handshake takes longer than 10 s.
  # --max-time: abort the entire request (including response body) after 30 s.
  response=$(curl -s -w "\n%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    -H "x-api-key: ${ANTHROPIC_ADMIN_API_KEY}" \
    -H "anthropic-version: ${API_VERSION}" \
    "${url}") || die "Network error: curl failed (timed out or connection refused). Check your internet connection."

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  case "$http_code" in
    200) ;;
    401) die "401 Unauthorized — your API key is invalid or has been revoked. Check ~/.config/anthropic-usage/api_key." ;;
    403) die "403 Forbidden — your key lacks Admin permissions, or your account is not on an Anthropic Organization plan. Usage reports require an Organization account." ;;
    404) die "404 Not Found — the usage report endpoint was not found. The API URL may have changed; please check for an updated version of this script." ;;
    429) die "429 Too Many Requests — you are being rate-limited. Wait a moment and try again." ;;
    5*)  die "Server error (HTTP ${http_code}) — the Anthropic API returned an unexpected error. Try again in a few minutes." ;;
    *)   die "Unexpected HTTP status ${http_code}. Response: ${body}" ;;
  esac

  echo "$body"
}

# Call the Anthropic usage API, following pagination until all buckets are
# collected. Returns a single JSON object with a "data" array that merges
# every page: { "data": [ ...all buckets... ] }
#
# Arguments:
#   $1 — starting_at (RFC3339)
#   $2 — ending_at   (RFC3339)
#   $3 — group_by    ("model" or "" for no grouping)
fetch_usage() {
  local starting_at="$1"
  local ending_at="$2"
  local group_by="$3"

  # Base query string. bucket_width=1d gives per-day granularity.
  local base_query="starting_at=${starting_at}&ending_at=${ending_at}&bucket_width=1d"
  if [[ -n "$group_by" ]]; then
    base_query="${base_query}&group_by%5B%5D=${group_by}"
  fi

  # With bucket_width=1d the API returns at most 31 buckets per page.
  # A 30-day window therefore needs at most 1 page; 100 is a hard ceiling
  # that guards against an infinite loop if the API misbehaves.
  local MAX_PAGES=100

  # Accumulate all data buckets across pages into a JSON array.
  local all_data="[]"
  local page_token=""
  local page_num=0

  while true; do
    if (( page_num >= MAX_PAGES )); then
      die "Pagination safety limit reached (${MAX_PAGES} pages). The API may be returning unexpected results."
    fi

    local query="$base_query"
    if [[ -n "$page_token" ]]; then
      query="${query}&page=${page_token}"
    fi

    local body
    body=$(_curl_usage "${API_BASE}?${query}")
    page_num=$(( page_num + 1 ))

    # Merge this page's buckets into the accumulated array.
    all_data=$(printf '%s\n%s' "$all_data" "$body" \
      | jq -s '.[0] + .[1].data')

    # Check for more pages.
    local has_more next_page
    has_more=$(echo "$body" | jq -r '.has_more // false')
    next_page=$(echo "$body" | jq -r '.next_page // ""')

    if [[ "$has_more" != "true" || -z "$next_page" ]]; then
      break
    fi

    page_token="$next_page"
  done

  # Emit a single envelope with the complete data array.
  jq -n --argjson data "$all_data" '{"data": $data}'
}

# -----------------------------------------------------------------------------
# RENDERING
# -----------------------------------------------------------------------------

# Print a markdown-friendly table of aggregated usage (no model breakdown).
#
# The API response structure (per bucket):
#   .data[] = { starting_at, ending_at, results: [ { uncached_input_tokens,
#               cache_read_input_tokens, cache_creation: { ephemeral_1h_input_tokens,
#               ephemeral_5m_input_tokens }, output_tokens, ... } ] }
#
# "Input tokens" here follows Anthropic's billing definition:
#   uncached input + cache reads + cache creation (both TTLs)
render_summary() {
  local label="$1"
  local json="$2"

  local total_uncached total_cache_read total_cache_creation total_output
  total_uncached=$(echo "$json" | jq '[.data[].results[].uncached_input_tokens // 0] | add // 0')
  total_cache_read=$(echo "$json" | jq '[.data[].results[].cache_read_input_tokens // 0] | add // 0')
  total_cache_creation=$(echo "$json" | jq '
    [.data[].results[] |
      ((.cache_creation.ephemeral_1h_input_tokens // 0) +
       (.cache_creation.ephemeral_5m_input_tokens // 0))
    ] | add // 0')
  total_output=$(echo "$json" | jq '[.data[].results[].output_tokens // 0] | add // 0')

  local total_input=$(( total_uncached + total_cache_read + total_cache_creation ))

  echo ""
  echo "## ${label}"
  echo ""
  echo "| Metric                  | Value                        |"
  echo "|-------------------------|------------------------------|"
  printf "| Uncached input tokens   | %-28s |\n" "$(format_number "$total_uncached")"
  printf "| Cache read tokens       | %-28s |\n" "$(format_number "$total_cache_read")"
  printf "| Cache creation tokens   | %-28s |\n" "$(format_number "$total_cache_creation")"
  printf "| Total input tokens      | %-28s |\n" "$(format_number "$total_input")"
  printf "| Output tokens           | %-28s |\n" "$(format_number "$total_output")"
  printf "| Total tokens            | %-28s |\n" "$(format_number "$(( total_input + total_output ))")"
  echo ""
}

# Print a markdown-friendly table broken down by model.
render_breakdown() {
  local label="$1"
  local json="$2"

  echo ""
  echo "## ${label} — by model"
  echo ""
  echo "| Model                                    | Input tokens  | Output tokens |"
  echo "|------------------------------------------|---------------|---------------|"

  # Aggregate per model across all buckets and pages.
  # Input = uncached + cache_read + cache_creation (both TTLs).
  echo "$json" | jq -r '
    reduce (.data[].results[]) as $r (
      {};
      ($r.model // "unknown") as $model |
      .[$model].input  += (($r.uncached_input_tokens // 0)
                          + ($r.cache_read_input_tokens // 0)
                          + ($r.cache_creation.ephemeral_1h_input_tokens // 0)
                          + ($r.cache_creation.ephemeral_5m_input_tokens // 0)) |
      .[$model].output += ($r.output_tokens // 0)
    )
    | to_entries
    | sort_by(-.value.input)
    | .[]
    | [.key, .value.input, .value.output]
    | @tsv
  ' | while IFS=$'\t' read -r model input output; do
      printf "| %-40s | %13s | %13s |\n" \
        "$model" \
        "$(format_number "$input")" \
        "$(format_number "$output")"
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
  echo "No period flag specified — defaulting to --weekly. Use --help to see all options." >&2
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

if [[ "$ANTHROPIC_ADMIN_API_KEY" != sk-ant-admin* ]]; then
  die "Invalid API key format. Anthropic Admin keys start with 'sk-ant-admin'. Check ${KEY_FILE}."
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

# Compute all boundary timestamps once so every period uses the same END and
# the same reference point, even if the clock ticks past midnight mid-run.
TODAY=$(date -u '+%Y-%m-%d')
END=$(tomorrow_utc)
START_DAILY=$(today_utc)
START_WEEKLY=$(date_n_days_ago 7)
START_MONTHLY=$(date_n_days_ago 30)

# ---- Daily ------------------------------------------------------------------
if $OPT_DAILY; then
  JSON=$(fetch_usage "$START_DAILY" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Today's usage (${TODAY})" "$JSON"
  else
    render_summary "Today's usage (${TODAY})" "$JSON"
  fi
fi

# ---- Weekly -----------------------------------------------------------------
if $OPT_WEEKLY; then
  JSON=$(fetch_usage "$START_WEEKLY" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Usage — past 7 days" "$JSON"
  else
    render_summary "Usage — past 7 days" "$JSON"
  fi
fi

# ---- Monthly ----------------------------------------------------------------
if $OPT_MONTHLY; then
  JSON=$(fetch_usage "$START_MONTHLY" "$END" "$GROUP_BY")

  if $OPT_BREAKDOWN; then
    render_breakdown "Usage — past 30 days" "$JSON"
  else
    render_summary "Usage — past 30 days" "$JSON"
  fi
fi

echo "Done."
