#!/usr/bin/env bash
set -euo pipefail

#############################################
# Cross-Tenant Health Audit Framework
#
# Optimized version:
#   - Single API call per host.
#   - Primary lookup is NOT filtered by Management Zone.
#   - managementZones are read from the same /api/v2/entities response.
#   - Company_B hosts are classified as:
#       MZ Company_A
#       MZ Not Company_A
#       UNKNOWN
#   - Company_A hosts show:
#       N/A
#############################################

RUN_USER="$(whoami)"
HOME_DIR="$(eval echo "~${RUN_USER}")"
RUN_TS="$(date +%s)"

CT_REPORTS_DIR="${CT_REPORTS_DIR:-${HOME_DIR}/dt_reports}"
REPORT_DIR="${REPORT_DIR:-${CT_REPORTS_DIR}}"
LOG_DIR="${LOG_DIR:-${CT_REPORTS_DIR}}"
DATA_DIR="${DATA_DIR:-${CT_REPORTS_DIR}}"

mkdir -p "$CT_REPORTS_DIR" "$REPORT_DIR" "$LOG_DIR" "$DATA_DIR"

CONFIG_PATH="${CONFIG_PATH:-${HOME_DIR}/.ct_health_audit.conf}"
if [[ ! -f "$CONFIG_PATH" && -f "${HOME_DIR}/.dt_env.conf" ]]; then
  CONFIG_PATH="${HOME_DIR}/.dt_env.conf"
fi

OUTPUT_PREFIX="${OUTPUT_PREFIX:-ct_health_audit}"

EXCLUSION_FILE="${EXCLUSION_FILE:-${DATA_DIR}/ct_health_audit_exclusions.csv}"
if [[ ! -f "$EXCLUSION_FILE" && -f "${DATA_DIR}/dt_connectivity_exclusions.csv" ]]; then
  EXCLUSION_FILE="${DATA_DIR}/dt_connectivity_exclusions.csv"
fi

PROD_LIST="${PROD_LIST:-${DATA_DIR}/servers_prod.txt}"
NONPROD_LIST="${NONPROD_LIST:-${DATA_DIR}/servers_non_prod.txt}"
Company_A_LIST="${Company_A_LIST:-${DATA_DIR}/servers_Company_A.txt}"

BOOTSTRAP_LOG="${LOG_DIR}/${OUTPUT_PREFIX}_bootstrap_${RUN_TS}.log"
LOG_FILE="$BOOTSTRAP_LOG"

REPORT_CSV=""
DISCOVERY_CSV=""
EXCLUDED_CSV=""
Company_B_EXEC_CSV=""
Company_A_EXEC_CSV=""

declare -A EXCLUSION_COMMENTS

###############################################################################
# HELPERS
###############################################################################
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

sanitize_csv_field() {
  local s="${1:-}"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//,/;}"
  s="${s//|/ }"
  echo "$s"
}

normalize_host_key() {
  local h="${1:-}"
  h="$(echo "$h" | tr '[:upper:]' '[:lower:]' | xargs)"
  h="${h%%.*}"
  h="$(echo "$h" | sed 's/[^a-z0-9_-]//g')"
  echo "$h"
}

normalize_env_key() {
  local e="${1:-}"
  e="$(echo "$e" | tr '[:lower:]' '[:upper:]' | xargs)"
  e="${e//-/_}"
  e="${e// /_}"

  case "$e" in
    Company_B_PROD|PROD|Company_B_PRODUCTION|PRODUCTION)
      echo "Company_B_PROD"
      ;;
    Company_B_NONPROD|Company_B_NON_PROD|NONPROD|NON_PROD|Company_B_NON_PRODUCTION|NON_PRODUCTION)
      echo "Company_B_NONPROD"
      ;;
    Company_A)
      echo "Company_A"
      ;;
    GLOBAL|ALL)
      echo "GLOBAL"
      ;;
    *)
      echo "$e"
      ;;
  esac
}

write_report_row() {
  local tenant_group="$1"
  local hostname="$2"
  local status="$3"
  local last_seen="$4"
  local age_human="$5"
  local matches="$6"
  local entity_id="${7:-}"
  local display_name="${8:-}"
  local in_Company_A_mz="${9:-}"
  local notes="${10:-}"

  display_name="$(sanitize_csv_field "$display_name")"
  notes="$(sanitize_csv_field "$notes")"

  echo "${tenant_group},${hostname},${status},${last_seen},${age_human},${matches},${entity_id},${display_name},${in_Company_A_mz},${notes}" >> "$REPORT_CSV"
}

write_excluded_row() {
  local expected_group="$1"
  local hostname="$2"
  local comments="$3"

  comments="$(sanitize_csv_field "$comments")"

  echo "${RUN_TS},${expected_group},${hostname},EXCLUDED_BY_BLACKLIST,${comments}" >> "$EXCLUDED_CSV"
}

need_cmd bash
need_cmd curl
need_cmd jq
need_cmd python3
need_cmd find
need_cmd sort
need_cmd awk
need_cmd wc
need_cmd date
need_cmd mktemp
need_cmd sed
need_cmd xargs
need_cmd cat

###############################################################################
# EXCEL DETECTION
###############################################################################
detect_excel() {
  if [[ -n "${EXCEL_PATH:-}" ]]; then
    EXCEL_PATH="$EXCEL_PATH"
  else
    EXCEL_PATH="$(
      find "$DATA_DIR" -maxdepth 1 -type f -name 'esl_report.*.xlsx' \
        -printf '%T@|%p\n' 2>/dev/null \
      | sort -nr \
      | awk -F'|' 'NR==1{print $2}'
    )"
  fi

  [[ -n "${EXCEL_PATH:-}" ]] || die "No Excel file found matching ${DATA_DIR}/esl_report.*.xlsx"
  [[ -f "$EXCEL_PATH" ]] || die "Excel file not found: $EXCEL_PATH"
}

###############################################################################
# LOAD CONFIG
###############################################################################
load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH"

  # shellcheck disable=SC1090
  source "$CONFIG_PATH"

  : "${TENANT_PROD_URL:?Missing TENANT_PROD_URL in $CONFIG_PATH}"
  : "${TOKEN_PROD:?Missing TOKEN_PROD in $CONFIG_PATH}"
  : "${TENANT_NONPROD_URL:?Missing TENANT_NONPROD_URL in $CONFIG_PATH}"
  : "${TOKEN_NONPROD:?Missing TOKEN_NONPROD in $CONFIG_PATH}"
  : "${TENANT_Company_A_URL:?Missing TENANT_Company_A_URL in $CONFIG_PATH}"
  : "${TOKEN_Company_A:?Missing TOKEN_Company_A in $CONFIG_PATH}"

  STALE_HOURS="${STALE_HOURS:-48}"
  EXEC_STALE_HOURS="${EXEC_STALE_HOURS:-2}"

  TENANT_PROD_URL="${TENANT_PROD_URL%/}"
  TENANT_NONPROD_URL="${TENANT_NONPROD_URL%/}"
  TENANT_Company_A_URL="${TENANT_Company_A_URL%/}"
}

###############################################################################
# LOAD EXCLUSIONS
###############################################################################
load_exclusions() {
  unset EXCLUSION_COMMENTS
  declare -g -A EXCLUSION_COMMENTS

  if [[ ! -f "$EXCLUSION_FILE" ]]; then
    log "Exclusion file not found: $EXCLUSION_FILE"
    log "No hosts will be excluded by blacklist."
    return 0
  fi

  log "Loading exclusion file: $EXCLUSION_FILE"

  local line_no=0
  local loaded=0
  local skipped=0

  while IFS=',' read -r env host comments; do
    line_no=$((line_no + 1))

    env="${env:-}"
    host="${host:-}"
    comments="${comments:-}"

    [[ -z "$(echo "$env$host$comments" | xargs)" ]] && continue
    [[ "$env" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line_no" -eq 1 ]]; then
      local header_env header_host
      header_env="$(echo "$env" | tr '[:upper:]' '[:lower:]' | xargs)"
      header_host="$(echo "$host" | tr '[:upper:]' '[:lower:]' | xargs)"
      if [[ "$header_env" == "environment" && "$header_host" == "host" ]]; then
        continue
      fi
    fi

    local env_key host_key
    env_key="$(normalize_env_key "$env")"
    host_key="$(normalize_host_key "$host")"

    if [[ -z "$env_key" || -z "$host_key" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    case "$env_key" in
      Company_B_PROD|Company_B_NONPROD|Company_A|GLOBAL)
        EXCLUSION_COMMENTS["${env_key}|${host_key}"]="$comments"
        loaded=$((loaded + 1))
        ;;
      *)
        log "WARNING: Invalid exclusion environment '${env}' on line ${line_no}. Allowed: Company_B_PROD, Company_B_NONPROD, Company_A, GLOBAL"
        skipped=$((skipped + 1))
        ;;
    esac
  done < "$EXCLUSION_FILE"

  log "Exclusions loaded: ${loaded}, skipped: ${skipped}"
}

get_exclusion_comment() {
  local expected_group="$1"
  local host="$2"

  local env_key host_key
  env_key="$(normalize_env_key "$expected_group")"
  host_key="$(normalize_host_key "$host")"

  local exact_key="${env_key}|${host_key}"
  local global_key="GLOBAL|${host_key}"

  if [[ -n "${EXCLUSION_COMMENTS[$exact_key]:-}" ]]; then
    echo "${EXCLUSION_COMMENTS[$exact_key]}"
    return 0
  fi

  if [[ -n "${EXCLUSION_COMMENTS[$global_key]:-}" ]]; then
    echo "${EXCLUSION_COMMENTS[$global_key]}"
    return 0
  fi

  return 1
}

is_excluded() {
  local expected_group="$1"
  local host="$2"

  if get_exclusion_comment "$expected_group" "$host" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

###############################################################################
# OUTPUT FILES
###############################################################################
set_output_files() {
  local run_label="$1"

  REPORT_CSV="${REPORT_DIR}/${OUTPUT_PREFIX}_${run_label}_report_${RUN_TS}.csv"
  DISCOVERY_CSV="${REPORT_DIR}/${OUTPUT_PREFIX}_${run_label}_notfound_discovery_${RUN_TS}.csv"
  EXCLUDED_CSV="${REPORT_DIR}/${OUTPUT_PREFIX}_${run_label}_excluded_${RUN_TS}.csv"

  Company_B_EXEC_CSV="${REPORT_DIR}/${OUTPUT_PREFIX}_Company_B_executive_summary_${RUN_TS}.csv"
  Company_A_EXEC_CSV="${REPORT_DIR}/${OUTPUT_PREFIX}_Company_A_executive_summary_${RUN_TS}.csv"

  local final_log="${LOG_DIR}/${OUTPUT_PREFIX}_${run_label}_report_${RUN_TS}.log"

  if [[ "$LOG_FILE" != "$final_log" ]]; then
    mv "$LOG_FILE" "$final_log" 2>/dev/null || true
    LOG_FILE="$final_log"
  fi

  log "Run label=${run_label}"
  log "Report=${REPORT_CSV}"
  log "Discovery report=${DISCOVERY_CSV}"
  log "Excluded report=${EXCLUDED_CSV}"
  log "Company_B executive summary=${Company_B_EXEC_CSV}"
  log "Company_A executive summary=${Company_A_EXEC_CSV}"
  log "Log=${LOG_FILE}"
}

###############################################################################
# BUILD SERVER LISTS FROM EXCEL
###############################################################################
build_lists_from_excel() {
  [[ -f "$EXCEL_PATH" ]] || die "Excel file not found: $EXCEL_PATH"

  log "Building server lists from Excel: $EXCEL_PATH"
  log "Outputs: $PROD_LIST | $NONPROD_LIST | $Company_A_LIST"

  : > "$PROD_LIST"
  : > "$NONPROD_LIST"
  : > "$Company_A_LIST"

  python3 - <<'PY' "$EXCEL_PATH" "$PROD_LIST" "$NONPROD_LIST" "$Company_A_LIST"
import sys
import re

try:
    import pandas as pd
except ModuleNotFoundError:
    print("ERROR: Missing Python module: pandas", file=sys.stderr)
    print("Install with: python3 -m pip install --user pandas openpyxl", file=sys.stderr)
    sys.exit(2)

excel_path, prod_out, nonprod_out, Company_A_out = sys.argv[1:5]

try:
    df = pd.read_excel(excel_path, engine="openpyxl")
except ModuleNotFoundError:
    print("ERROR: Missing Python module: openpyxl", file=sys.stderr)
    print("Install with: python3 -m pip install --user openpyxl", file=sys.stderr)
    sys.exit(2)

required = ["System Name", "Environment", "OS Class"]
for c in required:
    if c not in df.columns:
        print(f"ERROR: Missing column '{c}' in Excel. Found columns: {list(df.columns)}", file=sys.stderr)
        sys.exit(2)

Company_A_DOMAINS = [
    ".Company_Bg.svcs.entsvcs.com",
    ".entsvcs.net",
    ".resrc.entsvcs.com",
    ".oktul.us.eds.com",
    ".sabre.com",
    ".Company_B.Company_A.com",
    ".sharedmgmt.com",
    ".oraclevcn.com",
]

Company_B_DOMAINS = [
    ".corpCompany_B.Company_B.com",
    ".corpa.Company_B.com",
    ".qcorpCompany_B.Company_B.com",
    ".cdc.Company_B.com",
    ".tul.Company_B.com",
    ".pdc.Company_B.com",
    ".Company_Blcorp.Company_B.com",
    ".mgmt.Company_B.com",
]

Company_B_PROD_ENV = {"production"}

EXCLUDED_OS = {
    "ibm z",
    "openvms",
    "sunos/solaris",
    "vmware",
    "other",
}

def ends_with_any(name: str, suffixes) -> bool:
    return any(name.endswith(s) for s in suffixes)

def normalize_short(host_full: str):
    if host_full is None:
        return None

    s = str(host_full).strip().lower()
    if not s:
        return None

    s = s.split()[0].strip()
    short = s.split(".")[0].strip()
    short = re.sub(r"[^a-z0-9_-]", "", short)

    return short or None

prod = set()
nonprod = set()
Company_A = set()

skipped_os = 0
skipped_domain = 0
skipped_invalid = 0

for _, row in df.iterrows():
    host_full = str(row["System Name"]).strip().lower() if not pd.isna(row["System Name"]) else ""
    env = str(row["Environment"]).strip().lower() if not pd.isna(row["Environment"]) else ""
    os_class = str(row["OS Class"]).strip().lower() if not pd.isna(row["OS Class"]) else ""

    if os_class in EXCLUDED_OS:
        skipped_os += 1
        continue

    short = normalize_short(host_full)
    if not short:
        skipped_invalid += 1
        continue

    if ends_with_any(host_full, Company_A_DOMAINS):
        Company_A.add(short)
        continue

    if ends_with_any(host_full, Company_B_DOMAINS):
        if env in Company_B_PROD_ENV:
            prod.add(short)
        else:
            nonprod.add(short)
        continue

    skipped_domain += 1

with open(prod_out, "w") as f:
    for h in sorted(prod):
        f.write(h + "\n")

with open(nonprod_out, "w") as f:
    for h in sorted(nonprod):
        f.write(h + "\n")

with open(Company_A_out, "w") as f:
    for h in sorted(Company_A):
        f.write(h + "\n")

print(f"OK: PROD={len(prod)} NON-PROD={len(nonprod)} Company_A={len(Company_A)}", file=sys.stderr)
print(f"Skipped: OS={skipped_os} UnknownDomain={skipped_domain} InvalidHost={skipped_invalid}", file=sys.stderr)
PY

  sort -u "$PROD_LIST" -o "$PROD_LIST"
  sort -u "$NONPROD_LIST" -o "$NONPROD_LIST"
  sort -u "$Company_A_LIST" -o "$Company_A_LIST"

  log "List counts: PROD=$(wc -l < "$PROD_LIST" | tr -d ' ') NON-PROD=$(wc -l < "$NONPROD_LIST" | tr -d ' ') Company_A=$(wc -l < "$Company_A_LIST" | tr -d ' ')"
}

###############################################################################
# DYNATRACE API
###############################################################################
dt_query_host() {
  local tenant_url="$1"
  local token="$2"
  local host="$3"

  # Single API call:
  # - host lookup in full tenant
  # - lastSeenTms
  # - managementZones
  # entityId and displayName are always included by Dynatrace.
  curl -sSk -G \
    --connect-timeout 15 \
    --max-time 60 \
    -H "accept: application/json; charset=utf-8" \
    -H "Authorization: Api-Token ${token}" \
    "${tenant_url}/api/v2/entities" \
    --data-urlencode "pageSize=100" \
    --data-urlencode "entitySelector=type(HOST),entityName.startsWith(\"${host}\")" \
    --data-urlencode "from=now-365d" \
    --data-urlencode "fields=+lastSeenTms,+managementZones"
}

extract_match_count() {
  local json="$1"
  local host="$2"

  echo "$json" | jq -r --arg h "$host" '
    [.entities[]? | select((.displayName | ascii_downcase) | test("^" + ($h | ascii_downcase) + "(\\.|$)"))]
    | length
  ' 2>/dev/null || echo "0"
}

extract_latest_field() {
  local json="$1"
  local host="$2"
  local field="$3"

  echo "$json" | jq -r --arg h "$host" --arg f "$field" '
    [.entities[]? | select((.displayName | ascii_downcase) | test("^" + ($h | ascii_downcase) + "(\\.|$)"))]
    | sort_by(.lastSeenTms // 0)
    | reverse
    | .[0][$f] // empty
  ' 2>/dev/null || echo ""
}

check_Company_A_management_zone_from_json() {
  local label="$1"
  local json="$2"
  local host="$3"

  case "$label" in
    Company_B_PROD|Company_B_NONPROD)
      ;;
    *)
      echo "N/A"
      return 0
      ;;
  esac

  if [[ -z "$json" ]] || ! echo "$json" | jq empty >/dev/null 2>&1; then
    echo "UNKNOWN"
    return 0
  fi

  if echo "$json" | jq -e '.error' >/dev/null 2>&1; then
    echo "UNKNOWN"
    return 0
  fi

  local mz_count
  mz_count="$(echo "$json" | jq -r --arg h "$host" '
    [
      [.entities[]? | select((.displayName | ascii_downcase) | test("^" + ($h | ascii_downcase) + "(\\.|$)"))]
      | sort_by(.lastSeenTms // 0)
      | reverse
      | .[0].managementZones[]?
      | select(.name == "Company_A")
    ]
    | length
  ' 2>/dev/null || echo "0")"

  if [[ "$mz_count" =~ ^[0-9]+$ && "$mz_count" -gt 0 ]]; then
    echo "MZ Company_A"
  else
    echo "MZ Not Company_A"
  fi
}

###############################################################################
# CLASSIFY LAST SEEN
###############################################################################
classify_last_seen() {
  local last_seen_ms="$1"
  local stale_hours="$2"

  local now_ms
  now_ms="$(date +%s)000"

  if [[ -z "$last_seen_ms" || "$last_seen_ms" == "null" ]]; then
    echo "NO_LASTSEEN,,"
    return
  fi

  local age_ms=$(( now_ms - last_seen_ms ))
  if (( age_ms < 0 )); then age_ms=0; fi

  local age_s=$(( age_ms / 1000 ))
  local stale_s=$(( stale_hours * 3600 ))

  local d=$(( age_s / 86400 ))
  local h=$(( (age_s % 86400) / 3600 ))
  local m=$(( (age_s % 3600) / 60 ))
  local human="${d}d ${h}h ${m}m"

  if (( age_s > stale_s )); then
    echo "DISCONNECTED,${age_s},${human}"
  else
    echo "CONNECTED,${age_s},${human}"
  fi
}

###############################################################################
# PRE-CHECK
###############################################################################
precheck_tenant() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"

  log "Pre-check: testing connectivity to ${label} (${tenant_url})..."

  local tmp_body
  tmp_body="$(mktemp "/tmp/ct_precheck_${label}_${RUN_TS}_XXXXXX.json")"

  local http_code
  http_code="$(curl -sSk -o "$tmp_body" -w "%{http_code}" --connect-timeout 15 --max-time 60 -G \
    -H "accept: application/json; charset=utf-8" \
    -H "Authorization: Api-Token ${token}" \
    "${tenant_url}/api/v2/entities" \
    --data-urlencode "pageSize=1" \
    --data-urlencode "entitySelector=type(HOST)" \
    --data-urlencode "from=now-1d" 2>/dev/null || echo "000")"

  if grep -qi "failed to resolve tenant" "$tmp_body" 2>/dev/null; then
    log "ERROR: ${label} returned HTTP ${http_code}: tenant cannot be resolved by this gateway."
    head -5 "$tmp_body" | tee -a "$LOG_FILE" >&2
    rm -f "$tmp_body"
    return 1
  fi

  if [[ "$http_code" == "000" ]]; then
    log "ERROR: Cannot reach ${label} at ${tenant_url}."
    rm -f "$tmp_body"
    return 1
  elif [[ "$http_code" == "301" || "$http_code" == "302" ]]; then
    log "ERROR: ${label} returned HTTP ${http_code}. Endpoint is redirecting."
    rm -f "$tmp_body"
    return 1
  elif [[ "$http_code" == "401" ]]; then
    log "ERROR: ${label} returned HTTP 401. Check API token/scopes."
    rm -f "$tmp_body"
    return 1
  elif [[ "$http_code" =~ ^2 ]]; then
    log "Pre-check OK: ${label} reachable (HTTP ${http_code})"
    rm -f "$tmp_body"
    return 0
  else
    log "ERROR: ${label} returned HTTP ${http_code}. Body:"
    head -5 "$tmp_body" | tee -a "$LOG_FILE" >&2
    rm -f "$tmp_body"
    return 1
  fi
}

###############################################################################
# PROCESS LISTS
###############################################################################
process_list_as_api_error() {
  local label="$1"
  local list_file="$2"

  [[ -f "$list_file" ]] || die "List file not found: $list_file"

  log "Marking all non-excluded hosts as API_ERROR for tenant=${label} list=${list_file}"

  while IFS= read -r host; do
    [[ -z "$host" ]] && continue

    local exclusion_comment
    if exclusion_comment="$(get_exclusion_comment "$label" "$host" 2>/dev/null)"; then
      write_report_row "$label" "$host" "EXCLUDED_BY_BLACKLIST" "" "" "0" "" "" "N/A" "$exclusion_comment"
      write_excluded_row "$label" "$host" "$exclusion_comment"
      continue
    fi

    write_report_row "$label" "$host" "API_ERROR" "" "" "0" "" "" "UNKNOWN" ""
  done < "$list_file"
}

process_list_for_tenant() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"
  local list_file="$4"
  local stale_hours="$5"

  [[ -f "$list_file" ]] || die "List file not found: $list_file"

  local total_hosts
  total_hosts="$(wc -l < "$list_file" | tr -d ' ')"

  local current=0
  local excluded_count=0

  log "Processing tenant=${label} list=${list_file} (${total_hosts} hosts)"

  while IFS= read -r host; do
    [[ -z "$host" ]] && continue

    current=$((current + 1))

    if (( current % 25 == 0 )); then
      log "  Progress: ${current}/${total_hosts} (${label})"
    fi

    local exclusion_comment
    if exclusion_comment="$(get_exclusion_comment "$label" "$host" 2>/dev/null)"; then
      excluded_count=$((excluded_count + 1))
      write_report_row "$label" "$host" "EXCLUDED_BY_BLACKLIST" "" "" "0" "" "" "N/A" "$exclusion_comment"
      write_excluded_row "$label" "$host" "$exclusion_comment"
      continue
    fi

    local json
    json="$(dt_query_host "$tenant_url" "$token" "$host" 2>/dev/null || true)"

    if [[ -z "$json" ]] || ! echo "$json" | jq empty >/dev/null 2>&1; then
      write_report_row "$label" "$host" "API_ERROR" "" "" "0" "" "" "UNKNOWN" ""
      continue
    fi

    if echo "$json" | jq -e '.error' >/dev/null 2>&1; then
      local err_msg
      err_msg="$(echo "$json" | jq -r '.error.message // "unknown API error"' 2>/dev/null || echo "unknown API error")"
      log "  API_ERROR for host=${host}: ${err_msg}"
      write_report_row "$label" "$host" "API_ERROR" "" "" "0" "" "" "UNKNOWN" "$err_msg"
      continue
    fi

    local total
    total="$(extract_match_count "$json" "$host")"

    if [[ "$total" == "0" || -z "$total" ]]; then
      write_report_row "$label" "$host" "NOT_FOUND" "" "" "0" "" "" "UNKNOWN" ""
      continue
    fi

    local last_seen entity_id display_name in_Company_A_mz
    last_seen="$(extract_latest_field "$json" "$host" "lastSeenTms")"
    entity_id="$(extract_latest_field "$json" "$host" "entityId")"
    display_name="$(extract_latest_field "$json" "$host" "displayName")"
    in_Company_A_mz="$(check_Company_A_management_zone_from_json "$label" "$json" "$host")"

    local cls status age_s age_h
    cls="$(classify_last_seen "${last_seen:-null}" "$stale_hours")"

    status="$(echo "$cls" | cut -d',' -f1)"
    age_s="$(echo "$cls" | cut -d',' -f2)"
    age_h="$(echo "$cls" | cut -d',' -f3)"

    write_report_row "$label" "$host" "$status" "$last_seen" "$age_h" "$total" "$entity_id" "$display_name" "$in_Company_A_mz" ""

  done < "$list_file"

  log "  Completed: ${current}/${total_hosts} (${label}); excluded_by_blacklist=${excluded_count}"
}

###############################################################################
# PARALLEL GLOBAL
###############################################################################
run_tenant_job_to_files() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"
  local list_file="$4"
  local out_report="$5"
  local out_excluded="$6"

  REPORT_CSV="$out_report"
  EXCLUDED_CSV="$out_excluded"

  : > "$REPORT_CSV"
  : > "$EXCLUDED_CSV"

  if precheck_tenant "$label" "$tenant_url" "$token"; then
    process_list_for_tenant "$label" "$tenant_url" "$token" "$list_file" "$STALE_HOURS"
  else
    log "Pre-check failed for ${label}. Hosts will be marked as API_ERROR instead of NOT_FOUND."
    process_list_as_api_error "$label" "$list_file"
  fi
}

run_global_parallel() {
  log "Starting GLOBAL execution in parallel mode."

  local tmp_dir
  tmp_dir="$(mktemp -d "/tmp/ct_global_${RUN_TS}_XXXXXX")"

  local prod_report="${tmp_dir}/Company_B_prod.report.csv"
  local nonprod_report="${tmp_dir}/Company_B_nonprod.report.csv"
  local Company_A_report="${tmp_dir}/Company_A.report.csv"

  local prod_excluded="${tmp_dir}/Company_B_prod.excluded.csv"
  local nonprod_excluded="${tmp_dir}/Company_B_nonprod.excluded.csv"
  local Company_A_excluded="${tmp_dir}/Company_A.excluded.csv"

  log "GLOBAL temp directory=${tmp_dir}"

  (
    run_tenant_job_to_files "Company_B_PROD" "$TENANT_PROD_URL" "$TOKEN_PROD" "$PROD_LIST" "$prod_report" "$prod_excluded"
  ) &
  local pid_prod=$!

  (
    run_tenant_job_to_files "Company_B_NONPROD" "$TENANT_NONPROD_URL" "$TOKEN_NONPROD" "$NONPROD_LIST" "$nonprod_report" "$nonprod_excluded"
  ) &
  local pid_nonprod=$!

  (
    run_tenant_job_to_files "Company_A" "$TENANT_Company_A_URL" "$TOKEN_Company_A" "$Company_A_LIST" "$Company_A_report" "$Company_A_excluded"
  ) &
  local pid_Company_A=$!

  local rc=0

  wait "$pid_prod" || rc=1
  wait "$pid_nonprod" || rc=1
  wait "$pid_Company_A" || rc=1

  if (( rc != 0 )); then
    log "WARNING: One or more GLOBAL tenant jobs returned a non-zero exit code."
    log "         Continuing with whatever output files were generated."
  fi

  log "Merging GLOBAL tenant outputs into final report."

  [[ -f "$prod_report" ]] && cat "$prod_report" >> "$REPORT_CSV"
  [[ -f "$nonprod_report" ]] && cat "$nonprod_report" >> "$REPORT_CSV"
  [[ -f "$Company_A_report" ]] && cat "$Company_A_report" >> "$REPORT_CSV"

  [[ -f "$prod_excluded" ]] && cat "$prod_excluded" >> "$EXCLUDED_CSV"
  [[ -f "$nonprod_excluded" ]] && cat "$nonprod_excluded" >> "$EXCLUDED_CSV"
  [[ -f "$Company_A_excluded" ]] && cat "$Company_A_excluded" >> "$EXCLUDED_CSV"

  log "GLOBAL parallel execution completed."
}

###############################################################################
# DISCOVERY
###############################################################################
evaluate_host_in_tenant() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"
  local host="$4"
  local stale_hours="$5"

  if is_excluded "$label" "$host"; then
    echo "NO|EXCLUDED_BY_BLACKLIST||0|||N/A"
    return
  fi

  local json
  json="$(dt_query_host "$tenant_url" "$token" "$host" 2>/dev/null || true)"

  if [[ -z "$json" ]] || ! echo "$json" | jq empty >/dev/null 2>&1; then
    echo "ERROR|API_ERROR||0|||UNKNOWN"
    return
  fi

  if echo "$json" | jq -e '.error' >/dev/null 2>&1; then
    echo "ERROR|API_ERROR||0|||UNKNOWN"
    return
  fi

  local total
  total="$(extract_match_count "$json" "$host")"

  if [[ "$total" == "0" || -z "$total" ]]; then
    echo "NO|NOT_FOUND||0|||UNKNOWN"
    return
  fi

  local last_seen entity_id display_name in_Company_A_mz cls status
  last_seen="$(extract_latest_field "$json" "$host" "lastSeenTms")"
  entity_id="$(extract_latest_field "$json" "$host" "entityId")"
  display_name="$(extract_latest_field "$json" "$host" "displayName")"
  in_Company_A_mz="$(check_Company_A_management_zone_from_json "$label" "$json" "$host")"

  cls="$(classify_last_seen "${last_seen:-null}" "$stale_hours")"
  status="$(echo "$cls" | cut -d',' -f1)"

  display_name="$(sanitize_csv_field "$display_name")"

  echo "YES|${status}|${last_seen}|${total}|${entity_id}|${display_name}|${in_Company_A_mz}"
}

discovery_scan_tenant() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"
  local host_list="$4"
  local out_file="$5"

  : > "$out_file"

  local total_hosts
  total_hosts="$(wc -l < "$host_list" | tr -d ' ')"

  local current=0

  log "Discovery scan started for ${label}: ${total_hosts} hosts"

  while IFS= read -r host; do
    [[ -z "$host" ]] && continue

    current=$((current + 1))

    if (( current % 50 == 0 )); then
      log "  Discovery ${label} progress: ${current}/${total_hosts}"
    fi

    local result
    result="$(evaluate_host_in_tenant "$label" "$tenant_url" "$token" "$host" "$STALE_HOURS")"

    echo "${host}|${result}" >> "$out_file"

  done < "$host_list"

  log "Discovery scan completed for ${label}: ${current}/${total_hosts}"
}

run_notfound_discovery() {
  [[ -f "$REPORT_CSV" ]] || return 0

  local tmp_dir
  tmp_dir="$(mktemp -d "/tmp/ct_discovery_${RUN_TS}_XXXXXX")"

  local pairs_file="${tmp_dir}/notfound_pairs.csv"
  local hosts_file="${tmp_dir}/notfound_hosts.txt"

  tail -n +2 "$REPORT_CSV" \
    | awk -F',' '$3=="NOT_FOUND"{print $1","$2}' \
    | sort -u > "$pairs_file"

  local notfound_count
  notfound_count="$(wc -l < "$pairs_file" | tr -d ' ')"

  if [[ "$notfound_count" == "0" ]]; then
    log "No NOT_FOUND hosts detected. Discovery report not generated."
    return 0
  fi

  awk -F',' '{print $2}' "$pairs_file" | sort -u > "$hosts_file"

  local unique_hosts
  unique_hosts="$(wc -l < "$hosts_file" | tr -d ' ')"

  log "Starting parallel cross-tenant discovery."
  log "Discovery expected_group/hostname pairs=${notfound_count}"
  log "Discovery unique hosts=${unique_hosts}"
  log "Discovery CSV=${DISCOVERY_CSV}"
  log "Discovery temp directory=${tmp_dir}"

  local Company_B_prod_scan="${tmp_dir}/Company_B_prod.scan"
  local Company_B_nonprod_scan="${tmp_dir}/Company_B_nonprod.scan"
  local Company_A_scan="${tmp_dir}/Company_A.scan"

  (
    discovery_scan_tenant "Company_B_PROD" "$TENANT_PROD_URL" "$TOKEN_PROD" "$hosts_file" "$Company_B_prod_scan"
  ) &
  local pid_prod=$!

  (
    discovery_scan_tenant "Company_B_NONPROD" "$TENANT_NONPROD_URL" "$TOKEN_NONPROD" "$hosts_file" "$Company_B_nonprod_scan"
  ) &
  local pid_nonprod=$!

  (
    discovery_scan_tenant "Company_A" "$TENANT_Company_A_URL" "$TOKEN_Company_A" "$hosts_file" "$Company_A_scan"
  ) &
  local pid_Company_A=$!

  local rc=0

  wait "$pid_prod" || rc=1
  wait "$pid_nonprod" || rc=1
  wait "$pid_Company_A" || rc=1

  if (( rc != 0 )); then
    log "WARNING: One or more discovery tenant scans returned a non-zero exit code."
    log "         Continuing with available scan output."
  fi

  : > "$DISCOVERY_CSV"

  echo "run_ts,hostname,expected_group,original_status,found_in_Company_B_prod,Company_B_prod_status,Company_B_prod_lastSeenTms,Company_B_prod_matches,Company_B_prod_entityId,Company_B_prod_displayName,Company_B_prod_in_Company_A_management_zone,found_in_Company_B_nonprod,Company_B_nonprod_status,Company_B_nonprod_lastSeenTms,Company_B_nonprod_matches,Company_B_nonprod_entityId,Company_B_nonprod_displayName,Company_B_nonprod_in_Company_A_management_zone,found_in_Company_A,Company_A_status,Company_A_lastSeenTms,Company_A_matches,Company_A_entityId,Company_A_displayName,Company_A_in_Company_A_management_zone,resolved_location,resolution_status,matches_total" >> "$DISCOVERY_CSV"

  awk -F',' \
    -v run_ts="$RUN_TS" \
    -v Company_B_prod_scan="$Company_B_prod_scan" \
    -v Company_B_nonprod_scan="$Company_B_nonprod_scan" \
    -v Company_A_scan="$Company_A_scan" \
    -v out="$DISCOVERY_CSV" '
    BEGIN {
      while ((getline line < Company_B_prod_scan) > 0) {
        split(line,a,"|")
        h=a[1]
        ap_f[h]=a[2]; ap_s[h]=a[3]; ap_l[h]=a[4]; ap_m[h]=a[5]; ap_e[h]=a[6]; ap_d[h]=a[7]; ap_z[h]=a[8]
      }
      close(Company_B_prod_scan)

      while ((getline line < Company_B_nonprod_scan) > 0) {
        split(line,a,"|")
        h=a[1]
        an_f[h]=a[2]; an_s[h]=a[3]; an_l[h]=a[4]; an_m[h]=a[5]; an_e[h]=a[6]; an_d[h]=a[7]; an_z[h]=a[8]
      }
      close(Company_B_nonprod_scan)

      while ((getline line < Company_A_scan) > 0) {
        split(line,a,"|")
        h=a[1]
        dx_f[h]=a[2]; dx_s[h]=a[3]; dx_l[h]=a[4]; dx_m[h]=a[5]; dx_e[h]=a[6]; dx_d[h]=a[7]; dx_z[h]=a[8]
      }
      close(Company_A_scan)
    }
    {
      expected=$1
      host=$2

      if (ap_f[host]=="") { ap_f[host]="ERROR"; ap_s[host]="API_ERROR"; ap_z[host]="UNKNOWN" }
      if (an_f[host]=="") { an_f[host]="ERROR"; an_s[host]="API_ERROR"; an_z[host]="UNKNOWN" }
      if (dx_f[host]=="") { dx_f[host]="ERROR"; dx_s[host]="API_ERROR"; dx_z[host]="UNKNOWN" }

      ap_matches=ap_m[host]+0
      an_matches=an_m[host]+0
      dx_matches=dx_m[host]+0

      found_count=0
      error_count=0

      if (ap_f[host]=="YES") found_count++
      if (an_f[host]=="YES") found_count++
      if (dx_f[host]=="YES") found_count++

      if (ap_f[host]=="ERROR") error_count++
      if (an_f[host]=="ERROR") error_count++
      if (dx_f[host]=="ERROR") error_count++

      matches_total=ap_matches+an_matches+dx_matches

      resolved="NONE"
      resolution="NOT_FOUND_ALL_CONFIGURED_TENANTS"

      if (found_count==0) {
        resolved="NONE"
        if (error_count>0) resolution="NOT_FOUND_IN_CONFIGURED_TENANTS_WITH_API_ERRORS"
        else resolution="NOT_FOUND_ALL_CONFIGURED_TENANTS"
      } else if (found_count==1) {
        if (ap_f[host]=="YES") resolved="Company_B_PROD"
        else if (an_f[host]=="YES") resolved="Company_B_NONPROD"
        else if (dx_f[host]=="YES") resolved="Company_A"

        if (resolved==expected) resolution="FOUND_IN_EXPECTED_TENANT_ON_RETRY"
        else resolution="FOUND_IN_DIFFERENT_TENANT"
      } else {
        resolved="MULTIPLE"
        resolution="MULTI_TENANT_MATCH"
      }

      printf "%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%d\n",
        run_ts,
        host,
        expected,
        "NOT_FOUND",
        ap_f[host], ap_s[host], ap_l[host], ap_matches, ap_e[host], ap_d[host], ap_z[host],
        an_f[host], an_s[host], an_l[host], an_matches, an_e[host], an_d[host], an_z[host],
        dx_f[host], dx_s[host], dx_l[host], dx_matches, dx_e[host], dx_d[host], dx_z[host],
        resolved,
        resolution,
        matches_total >> out
    }
  ' "$pairs_file"

  log "Discovery completed. File: ${DISCOVERY_CSV}"

  log "Discovery summary (resolution_status,count):"
  tail -n +2 "$DISCOVERY_CSV" \
    | awk -F',' '{c[$27]++} END{for(k in c) print k","c[k]}' \
    | sort \
    | tee -a "$LOG_FILE" >&2
}

###############################################################################
# EXECUTIVE SUMMARIES
###############################################################################
generate_executive_summaries() {
  log "Generating executive summaries with EXEC_STALE_HOURS=${EXEC_STALE_HOURS}"

  : > "$Company_B_EXEC_CSV"
  : > "$Company_A_EXEC_CSV"

  echo "run_ts,category,tenant_or_expected,hostname,age_hours,age_human,lastSeenTms,entityId,displayName,in_Company_A_management_zone,source_file" >> "$Company_B_EXEC_CSV"
  echo "run_ts,category,tenant_or_expected,hostname,age_hours,age_human,lastSeenTms,entityId,displayName,in_Company_A_management_zone,source_file" >> "$Company_A_EXEC_CSV"

  if [[ -f "$REPORT_CSV" && -s "$REPORT_CSV" ]]; then
    awk -F',' \
      -v now_ms="$(($(date +%s)*1000))" \
      -v th="${EXEC_STALE_HOURS}" \
      -v run_ts="${RUN_TS}" \
      -v Company_B_out="$Company_B_EXEC_CSV" \
      -v Company_A_out="$Company_A_EXEC_CSV" \
      -v src="$REPORT_CSV" '
      NR==1 { next }
      {
        tenant=$1; host=$2; status=$3; last=$4; age_h=$5; entity=$7; display=$8; mz=$9

        if (last=="" || last=="null") next
        if (status=="NOT_FOUND" || status=="API_ERROR" || status=="EXCLUDED_BY_BLACKLIST" || status=="NO_LASTSEEN") next

        age_hours=(now_ms-last)/3600000.0
        if (age_hours < th) next

        category="STALE_" th "H_PLUS"

        if (tenant=="Company_B_PROD" || tenant=="Company_B_NONPROD") {
          printf "%s,%s,%s,%s,%.2f,%s,%s,%s,%s,%s,%s\n", run_ts, category, tenant, host, age_hours, age_h, last, entity, display, mz, src >> Company_B_out
        }

        if (tenant=="Company_A") {
          printf "%s,%s,%s,%s,%.2f,%s,%s,%s,%s,%s,%s\n", run_ts, category, tenant, host, age_hours, age_h, last, entity, display, mz, src >> Company_A_out
        }
      }
    ' "$REPORT_CSV"
  fi

  if [[ -f "$DISCOVERY_CSV" && -s "$DISCOVERY_CSV" ]]; then
    awk -F',' \
      -v run_ts="${RUN_TS}" \
      -v Company_B_out="$Company_B_EXEC_CSV" \
      -v Company_A_out="$Company_A_EXEC_CSV" \
      -v src="$DISCOVERY_CSV" '
      NR==1 { next }
      {
        host=$2
        expected=$3
        resolution=$27

        if (resolution!="NOT_FOUND_ALL_CONFIGURED_TENANTS") next

        category="NOT_FOUND_ALL_TENANTS"

        if (expected=="Company_B_PROD" || expected=="Company_B_NONPROD") {
          printf "%s,%s,%s,%s,,,,,,,%s\n", run_ts, category, expected, host, src >> Company_B_out
        }

        if (expected=="Company_A") {
          printf "%s,%s,%s,%s,,,,,,,%s\n", run_ts, category, expected, host, src >> Company_A_out
        }
      }
    ' "$DISCOVERY_CSV"
  fi

  log "Executive summaries created:"
  log "  Company_B:  ${Company_B_EXEC_CSV}"
  log "  Company_A: ${Company_A_EXEC_CSV}"

  log "Executive summary counts:"
  log "  Company_B rows:  $(tail -n +2 "$Company_B_EXEC_CSV" | wc -l | tr -d ' ')"
  log "  Company_A rows: $(tail -n +2 "$Company_A_EXEC_CSV" | wc -l | tr -d ' ')"
}

###############################################################################
# MENU / SUMMARY / MAIN
###############################################################################
show_menu() {
  cat <<EOF

Select target:
  1) Company_B PROD       ($(wc -l < "$PROD_LIST" | tr -d ' ') hosts)
  2) Company_B NON-PROD   ($(wc -l < "$NONPROD_LIST" | tr -d ' ') hosts)
  3) Company_A            ($(wc -l < "$Company_A_LIST" | tr -d ' ') hosts)
  4) ALL / GLOBAL   (PROD + NON-PROD + Company_A)
  5) Build lists only (no API calls)
  0) Exit

EOF
}

print_summary() {
  log "Summary (tenant_group,status,count):"

  if [[ -s "$REPORT_CSV" ]]; then
    tail -n +2 "$REPORT_CSV" \
      | awk -F',' '{k=$1","$3; c[k]++} END{for(k in c) print k","c[k]}' \
      | sort \
      | tee -a "$LOG_FILE" >&2
  else
    log "No report data found."
  fi

  echo ""
  echo "Files:"
  echo "  Main report:           $REPORT_CSV"
  echo "  Log:                   $LOG_FILE"

  [[ -f "$DISCOVERY_CSV" ]] && echo "  Discovery report:      $DISCOVERY_CSV"
  [[ -f "$EXCLUDED_CSV" ]] && echo "  Excluded report:       $EXCLUDED_CSV"
  [[ -f "$Company_B_EXEC_CSV" ]] && echo "  Company_B executive summary:  $Company_B_EXEC_CSV"
  [[ -f "$Company_A_EXEC_CSV" ]] && echo "  Company_A executive summary: $Company_A_EXEC_CSV"
}

run_tenant() {
  local label="$1"
  local tenant_url="$2"
  local token="$3"
  local list_file="$4"

  if precheck_tenant "$label" "$tenant_url" "$token"; then
    process_list_for_tenant "$label" "$tenant_url" "$token" "$list_file" "$STALE_HOURS"
  else
    log "Pre-check failed for ${label}. Hosts will be marked as API_ERROR instead of NOT_FOUND."
    process_list_as_api_error "$label" "$list_file"
  fi
}

init_output_csvs() {
  : > "$REPORT_CSV"
  echo "tenant_group,hostname,status,lastSeenTms,age_human,matches,entityId,displayName,in_Company_A_management_zone,notes" >> "$REPORT_CSV"

  : > "$EXCLUDED_CSV"
  echo "run_ts,expected_group,hostname,status,comments" >> "$EXCLUDED_CSV"
}

main() {
  : > "$LOG_FILE"

  detect_excel
  load_config
  load_exclusions

  log "Framework=Cross-Tenant Health Audit Framework"
  log "User=${RUN_USER} HOME_DIR=${HOME_DIR}"
  log "Config=${CONFIG_PATH}"
  log "Data directory=${DATA_DIR}"
  log "Excel=${EXCEL_PATH}"
  log "Exclusion file=${EXCLUSION_FILE}"
  log "Stale threshold=${STALE_HOURS}h"
  log "Executive stale threshold=${EXEC_STALE_HOURS}h"
  log "Run timestamp=${RUN_TS}"
  log "Company_B Management Zone validation=Company_A"
  log "Company_B Management Zone source=managementZones field from primary entity lookup"
  log "Company_B Management Zone output values=MZ Company_A / MZ Not Company_A / UNKNOWN / N/A"
  log "Primary lookup Management Zone filter=DISABLED"
  log "API optimization=single host lookup call includes +managementZones"
  log "Parallel mode=tenant-level only"

  build_lists_from_excel

  show_menu
  read -r -p "Option: " opt

  case "$opt" in
    1)
      set_output_files "Company_B_prod"
      init_output_csvs
      run_tenant "Company_B_PROD" "$TENANT_PROD_URL" "$TOKEN_PROD" "$PROD_LIST"
      ;;

    2)
      set_output_files "Company_B_nonprod"
      init_output_csvs
      run_tenant "Company_B_NONPROD" "$TENANT_NONPROD_URL" "$TOKEN_NONPROD" "$NONPROD_LIST"
      ;;

    3)
      set_output_files "Company_A"
      init_output_csvs
      run_tenant "Company_A" "$TENANT_Company_A_URL" "$TOKEN_Company_A" "$Company_A_LIST"
      ;;

    4)
      set_output_files "global"
      init_output_csvs
      run_global_parallel
      ;;

    5)
      set_output_files "build_only"
      log "Build-only selected. Lists generated. Exiting."
      echo "Lists generated:"
      echo "  $PROD_LIST"
      echo "  $NONPROD_LIST"
      echo "  $Company_A_LIST"
      echo "Log saved to:"
      echo "  $LOG_FILE"
      exit 0
      ;;

    0)
      set_output_files "exit"
      log "Exit."
      exit 0
      ;;

    *)
      set_output_files "invalid"
      die "Invalid option"
      ;;
  esac

  log "Primary report completed."

  run_notfound_discovery
  generate_executive_summaries

  log "DONE."
  print_summary
}

main "$@"
