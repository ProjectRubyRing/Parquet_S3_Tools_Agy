#!/usr/bin/env bash
# ==============================================================================
# AWS VPC Flow Logs (Parquet) Viewer for RHEL 9.8 / Linux
# ==============================================================================
# Usage:
#   ./view_vpc_flow_logs.sh [OPTIONS] <FILE_OR_DIRECTORY>
#
# Examples:
#   ./view_vpc_flow_logs.sh ./test_data/single_sample.parquet
#   ./view_vpc_flow_logs.sh ./test_data/s3
#   ./view_vpc_flow_logs.sh --stats ./test_data/s3
#   ./view_vpc_flow_logs.sh --action REJECT --protocol TCP ./test_data/s3
#   ./view_vpc_flow_logs.sh --format csv -o output.csv ./test_data/s3
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${HOME}/.cache/vpc_flow_logs"
EMBEDDED_BIN="${CACHE_DIR}/duckdb"
LOCAL_BIN="${SCRIPT_DIR}/bin/duckdb"
DUCKDB_CMD=""

# --- Color definitions ---
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" -eq 0 ]]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_GREEN="\033[32m"
    COLOR_RED="\033[31m"
    COLOR_YELLOW="\033[33m"
    COLOR_CYAN="\033[36m"
    COLOR_BLUE="\033[34m"
    COLOR_MAGENTA="\033[35m"
    COLOR_DIM="\033[2m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_DIM=""
fi

# --- Helper: Print Usage ---
usage() {
    cat <<EOF
${COLOR_BOLD}AWS VPC Flow Logs (Parquet) Viewer for RHEL 9.8 / Linux${COLOR_RESET}

${COLOR_BOLD}USAGE:${COLOR_RESET}
    $(basename "$0") [OPTIONS] <FILE_OR_DIRECTORY>

${COLOR_BOLD}ARGUMENTS:${COLOR_RESET}
    <FILE_OR_DIRECTORY>   Path to a .parquet file or directory containing .parquet files

${COLOR_BOLD}OPTIONS:${COLOR_RESET}
    -a, --action ACTION       Filter by action: ACCEPT, REJECT, or ALL (default: ALL)
    -p, --protocol PROTO      Filter by protocol: TCP, UDP, ICMP, etc., or number (6, 17, 1)
    -s, --src IP              Filter by source IP address
    -d, --dst IP              Filter by destination IP address
    -i, --ip IP               Filter by IP (matches either source or destination)
    --srcport PORT            Filter by source port
    --dstport PORT            Filter by destination port
    --port PORT               Filter by port (matches either source or destination)
    -l, --limit N             Limit number of records to display (default: all)
    --sort FIELD              Sort by: time (default), bytes, packets, src, dst
    --order ORDER             Sort order: ASC (default) or DESC
    -f, --format FORMAT       Output format: table (default), detail, csv, tsv, json
    -o, --output FILE         Save output to file (also displays on screen)
    --stats                   Display summary statistics dashboard instead of raw table
    --all-columns             Display all columns in parquet files
    --no-recurse              Do not recursively scan subdirectories
    --no-color                Disable ANSI terminal color codes
    -h, --help                Show this help message

EOF
    exit 0
}

# --- Extract Bundled Engine if Needed ---
extract_bundled_engine() {
    local payload_start
    payload_start=$(grep -n "^__DUCKDB_PAYLOAD_START__$" "$0" | head -n 1 | cut -d: -f1 || true)
    if [[ -z "${payload_start}" ]]; then
        echo -e "${COLOR_RED}[ERROR] DuckDB binary not found in PATH or ${LOCAL_BIN}, and no bundled payload embedded.${COLOR_RESET}" >&2
        echo "Please place the 'duckdb' binary in '${LOCAL_BIN}' or add it to PATH." >&2
        exit 1
    fi

    mkdir -p "${CACHE_DIR}"
    echo -e "${COLOR_CYAN}[INFO] Extracting bundled Parquet parser engine to ${EMBEDDED_BIN} (one-time setup)...${COLOR_RESET}" >&2

    # Check required tools for extraction
    if ! command -v base64 >/dev/null 2>&1; then
        echo "[ERROR] 'base64' command is required for bundle extraction." >&2
        exit 1
    fi
    if ! command -v xz >/dev/null 2>&1; then
        echo "[ERROR] 'xz' command is required for bundle extraction." >&2
        exit 1
    fi

    tail -n +"$((payload_start + 1))" "$0" | base64 -d | xz -d > "${EMBEDDED_BIN}.tmp"
    chmod +x "${EMBEDDED_BIN}.tmp"
    mv -f "${EMBEDDED_BIN}.tmp" "${EMBEDDED_BIN}"
    DUCKDB_CMD="${EMBEDDED_BIN}"
    echo -e "${COLOR_GREEN}[INFO] Bundled engine successfully initialized.${COLOR_RESET}" >&2
}

# --- Resolve DuckDB Engine ---
find_duckdb_engine() {
    # 1. Local bin next to script
    if [[ -x "${LOCAL_BIN}" ]]; then
        DUCKDB_CMD="${LOCAL_BIN}"
        return 0
    fi

    # 2. PATH
    if command -v duckdb >/dev/null 2>&1; then
        DUCKDB_CMD="$(command -v duckdb)"
        return 0
    fi

    # 3. Cache directory
    if [[ -x "${EMBEDDED_BIN}" ]]; then
        DUCKDB_CMD="${EMBEDDED_BIN}"
        return 0
    fi

    # 4. Extract embedded payload
    extract_bundled_engine
}

# --- Argument Parsing ---
ACTION="ALL"
PROTOCOL=""
SRCADDR=""
DSTADDR=""
IP=""
SRCPORT=0
DSTPORT=0
PORT=0
LIMIT=0
SORT="time"
ORDER="ASC"
FORMAT="table"
OUTFILE=""
STATS_MODE="false"
ALL_COLUMNS="false"
RECURSE="true"
TARGET_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -a|--action)
            ACTION="${2:-}"
            shift 2
            ;;
        -p|--protocol)
            PROTOCOL="${2:-}"
            shift 2
            ;;
        -s|--src)
            SRCADDR="${2:-}"
            shift 2
            ;;
        -d|--dst)
            DSTADDR="${2:-}"
            shift 2
            ;;
        -i|--ip)
            IP="${2:-}"
            shift 2
            ;;
        --srcport)
            SRCPORT="${2:-0}"
            shift 2
            ;;
        --dstport)
            DSTPORT="${2:-0}"
            shift 2
            ;;
        --port)
            PORT="${2:-0}"
            shift 2
            ;;
        -l|--limit)
            LIMIT="${2:-0}"
            shift 2
            ;;
        --sort)
            SORT="${2:-time}"
            shift 2
            ;;
        --order)
            ORDER="${2:-ASC}"
            shift 2
            ;;
        -f|--format)
            FORMAT="${2:-table}"
            shift 2
            ;;
        -o|--output)
            OUTFILE="${2:-}"
            shift 2
            ;;
        --stats)
            STATS_MODE="true"
            shift
            ;;
        --all-columns)
            ALL_COLUMNS="true"
            shift
            ;;
        --no-recurse)
            RECURSE="false"
            shift
            ;;
        --no-color)
            COLOR_RESET=""
            COLOR_BOLD=""
            COLOR_GREEN=""
            COLOR_RED=""
            COLOR_YELLOW=""
            COLOR_CYAN=""
            COLOR_BLUE=""
            COLOR_MAGENTA=""
            COLOR_DIM=""
            shift
            ;;
        -*)
            echo -e "${COLOR_RED}[ERROR] Unknown option: $1${COLOR_RESET}" >&2
            echo "Use -h or --help for usage details." >&2
            exit 1
            ;;
        *)
            if [[ -z "${TARGET_PATH}" ]]; then
                TARGET_PATH="$1"
            else
                echo -e "${COLOR_RED}[ERROR] Unexpected multiple targets: $1${COLOR_RESET}" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${TARGET_PATH}" ]]; then
    echo -e "${COLOR_RED}[ERROR] Target file or directory is required.${COLOR_RESET}" >&2
    echo "Usage: $(basename "$0") [OPTIONS] <FILE_OR_DIRECTORY>" >&2
    exit 1
fi

if [[ ! -e "${TARGET_PATH}" ]]; then
    echo -e "${COLOR_RED}[ERROR] Target does not exist: '${TARGET_PATH}'${COLOR_RESET}" >&2
    exit 1
fi

# --- Locate Engine ---
find_duckdb_engine

# --- Resolve Files and DuckDB Expression ---
FILE_COUNT=0
DUCKDB_EXPR=""

if [[ -d "${TARGET_PATH}" ]]; then
    CLEAN_DIR="${TARGET_PATH%/}"
    if [[ "${RECURSE}" == "true" ]]; then
        FILE_COUNT=$(find "${CLEAN_DIR}" -type f -name "*.parquet" 2>/dev/null | wc -l || echo 0)
        DUCKDB_EXPR="'${CLEAN_DIR}/**/*.parquet'"
    else
        FILE_COUNT=$(find "${CLEAN_DIR}" -maxdepth 1 -type f -name "*.parquet" 2>/dev/null | wc -l || echo 0)
        DUCKDB_EXPR="'${CLEAN_DIR}/*.parquet'"
    fi

    if [[ "${FILE_COUNT}" -eq 0 ]]; then
        echo -e "${COLOR_RED}[ERROR] No .parquet files found in directory: '${TARGET_PATH}'${COLOR_RESET}" >&2
        exit 1
    fi
else
    FILE_COUNT=1
    DUCKDB_EXPR="'${TARGET_PATH}'"
fi

# --- Inspect Parquet Schema Columns ---
COLUMNS_RAW="$("${DUCKDB_CMD}" -noheader -list -c "SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) LIMIT 1);")"
if [[ -z "${COLUMNS_RAW}" ]]; then
    echo -e "${COLOR_RED}[ERROR] Failed to read Parquet metadata from: ${TARGET_PATH}${COLOR_RESET}" >&2
    exit 1
fi

HAS_TCP_FLAGS=0
HAS_FLOW_DIR=0
HAS_VPC_ID=0
HAS_SUBNET_ID=0
HAS_INSTANCE_ID=0

while IFS= read -r col; do
    col="$(echo "$col" | tr -d ' \r\n')"
    case "$col" in
        tcp_flags) HAS_TCP_FLAGS=1 ;;
        flow_direction) HAS_FLOW_DIR=1 ;;
        vpc_id) HAS_VPC_ID=1 ;;
        subnet_id) HAS_SUBNET_ID=1 ;;
        instance_id) HAS_INSTANCE_ID=1 ;;
    esac
done <<< "${COLUMNS_RAW}"

# --- Build WHERE Clauses ---
WHERE_CLAUSES=()

if [[ "${ACTION}" != "ALL" && -n "${ACTION}" ]]; then
    ACTION_UPPER="$(echo "${ACTION}" | tr '[:lower:]' '[:upper:]')"
    WHERE_CLAUSES+=("action = '${ACTION_UPPER}'")
fi

if [[ -n "${PROTOCOL}" ]]; then
    if [[ "${PROTOCOL}" =~ ^[0-9]+$ ]]; then
        WHERE_CLAUSES+=("protocol = ${PROTOCOL}")
    else
        PROTO_UPPER="$(echo "${PROTOCOL}" | tr '[:lower:]' '[:upper:]')"
        case "${PROTO_UPPER}" in
            ICMP)   WHERE_CLAUSES+=("protocol = 1") ;;
            IGMP)   WHERE_CLAUSES+=("protocol = 2") ;;
            TCP)    WHERE_CLAUSES+=("protocol = 6") ;;
            UDP)    WHERE_CLAUSES+=("protocol = 17") ;;
            IPV6)   WHERE_CLAUSES+=("protocol = 41") ;;
            GRE)    WHERE_CLAUSES+=("protocol = 47") ;;
            ESP)    WHERE_CLAUSES+=("protocol = 50") ;;
            AH)     WHERE_CLAUSES+=("protocol = 51") ;;
            ICMPV6) WHERE_CLAUSES+=("protocol = 58") ;;
            OSPF)   WHERE_CLAUSES+=("protocol = 89") ;;
            *)      WHERE_CLAUSES+=("protocol = '${PROTOCOL}'") ;;
        esac
    fi
fi

if [[ -n "${SRCADDR}" ]]; then WHERE_CLAUSES+=("srcaddr = '${SRCADDR}'"); fi
if [[ -n "${DSTADDR}" ]]; then WHERE_CLAUSES+=("dstaddr = '${DSTADDR}'"); fi
if [[ -n "${IP}" ]]; then WHERE_CLAUSES+=("(srcaddr = '${IP}' OR dstaddr = '${IP}')"); fi

if [[ "${SRCPORT}" -gt 0 ]]; then WHERE_CLAUSES+=("srcport = ${SRCPORT}"); fi
if [[ "${DSTPORT}" -gt 0 ]]; then WHERE_CLAUSES+=("dstport = ${DSTPORT}"); fi
if [[ "${PORT}" -gt 0 ]]; then WHERE_CLAUSES+=("(srcport = ${PORT} OR dstport = ${PORT})"); fi

WHERE_SQL=""
if [[ ${#WHERE_CLAUSES[@]} -gt 0 ]]; then
    IFS=" AND "
    WHERE_SQL="WHERE ${WHERE_CLAUSES[*]}"
    unset IFS
fi

# --- Helper: Run Query and Optionally Write Output ---
execute_and_display() {
    local cmd="$1"
    local raw_output
    raw_output=$(eval "${cmd}")

    if [[ -n "${OUTFILE}" ]]; then
        # Strip ANSI escape codes when saving to file
        echo "${raw_output}" | sed -r "s/\x1B\[[0-9;]*[a-zA-Z]//g" > "${OUTFILE}"
    fi

    # Display on screen
    echo "${raw_output}"

    if [[ -n "${OUTFILE}" ]]; then
        echo -e "${COLOR_GREEN}Output successfully saved to: ${OUTFILE}${COLOR_RESET}" >&2
    fi
}

# --- Statistics Dashboard Mode ---
if [[ "${STATS_MODE}" == "true" ]]; then
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD} AWS VPC Flow Logs - Summary Statistics Dashboard${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e " Target Path      : ${TARGET_PATH}"
    echo -e " Parquet Files    : ${FILE_COUNT} file(s)"

    STATS_SQL="
SELECT 
    count(*) AS total_flows,
    coalesce(sum(packets), 0) AS total_packets,
    coalesce(sum(bytes), 0) AS total_bytes,
    count(*) FILTER (WHERE action = 'ACCEPT') AS accept_count,
    count(*) FILTER (WHERE action = 'REJECT') AS reject_count,
    coalesce(strftime(to_timestamp(min(start)), '%Y-%m-%d %H:%M:%S'), '-') AS min_time,
    coalesce(strftime(to_timestamp(max(columns('^end$'))), '%Y-%m-%d %H:%M:%S'), '-') AS max_time
FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true)
${WHERE_SQL};
"
    STATS_JSON="$("${DUCKDB_CMD}" -json -c "${STATS_SQL}")"

    # Parse JSON stats with python or awk
    if command -v python3 >/dev/null 2>&1; then
        STATS_BANNER=$(python3 -c "
import json, sys

data = json.loads('''${STATS_JSON}''')[0]
total_flows = data.get('total_flows', 0)
total_packets = data.get('total_packets', 0)
total_bytes = data.get('total_bytes', 0)
accept_cnt = data.get('accept_count', 0)
reject_cnt = data.get('reject_count', 0)
min_time = data.get('min_time', '-')
max_time = data.get('max_time', '-')

def fmt_bytes(b):
    if b >= 1024**4: return f'{b/(1024**4):.2f} TB'
    if b >= 1024**3: return f'{b/(1024**3):.2f} GB'
    if b >= 1024**2: return f'{b/(1024**2):.2f} MB'
    if b >= 1024:    return f'{b/1024:.2f} KB'
    return f'{b:,} B'

accept_pct = (accept_cnt / total_flows * 100) if total_flows > 0 else 0
reject_pct = (reject_cnt / total_flows * 100) if total_flows > 0 else 0

print(f' Time Range       : {min_time} ~ {max_time}')
print(f' Total Flows      : {total_flows:,}')
print(f' Total Packets    : {total_packets:,}')
print(f' Total Bytes      : {fmt_bytes(total_bytes)} ({total_bytes:,} bytes)')
print(f' ACCEPT Flows     : {accept_cnt:,} ({accept_pct:.1f}%)')
print(f' REJECT Flows     : {reject_cnt:,} ({reject_pct:.1f}%)')
")
        echo "${STATS_BANNER}"
    else
        "${DUCKDB_CMD}" -box -c "${STATS_SQL}"
    fi

    echo -e "\n${COLOR_BOLD}--- Top 5 Source IPs (by Bytes) ---${COLOR_RESET}"
    "${DUCKDB_CMD}" -box -c "
SELECT 
    srcaddr AS source_ip, 
    count(*) AS flows, 
    sum(packets) AS packets, 
    CASE 
        WHEN sum(bytes) >= 1099511627776 THEN round(sum(bytes)/1099511627776.0, 2) || ' TB'
        WHEN sum(bytes) >= 1073741824 THEN round(sum(bytes)/1073741824.0, 2) || ' GB'
        WHEN sum(bytes) >= 1048576 THEN round(sum(bytes)/1048576.0, 2) || ' MB'
        WHEN sum(bytes) >= 1024 THEN round(sum(bytes)/1024.0, 2) || ' KB'
        ELSE sum(bytes) || ' B'
    END AS bytes_transferred
FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) 
${WHERE_SQL}
GROUP BY srcaddr 
ORDER BY sum(bytes) DESC 
LIMIT 5;
"

    echo -e "\n${COLOR_BOLD}--- Top 5 Destination IPs (by Bytes) ---${COLOR_RESET}"
    "${DUCKDB_CMD}" -box -c "
SELECT 
    dstaddr AS destination_ip, 
    count(*) AS flows, 
    sum(packets) AS packets, 
    CASE 
        WHEN sum(bytes) >= 1099511627776 THEN round(sum(bytes)/1099511627776.0, 2) || ' TB'
        WHEN sum(bytes) >= 1073741824 THEN round(sum(bytes)/1073741824.0, 2) || ' GB'
        WHEN sum(bytes) >= 1048576 THEN round(sum(bytes)/1048576.0, 2) || ' MB'
        WHEN sum(bytes) >= 1024 THEN round(sum(bytes)/1024.0, 2) || ' KB'
        ELSE sum(bytes) || ' B'
    END AS bytes_transferred
FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) 
${WHERE_SQL}
GROUP BY dstaddr 
ORDER BY sum(bytes) DESC 
LIMIT 5;
"

    echo -e "\n${COLOR_BOLD}--- Top 5 Destination Ports (by Flows) ---${COLOR_RESET}"
    "${DUCKDB_CMD}" -box -c "
SELECT 
    dstport AS destination_port, 
    count(*) AS flows, 
    CASE 
        WHEN sum(bytes) >= 1099511627776 THEN round(sum(bytes)/1099511627776.0, 2) || ' TB'
        WHEN sum(bytes) >= 1073741824 THEN round(sum(bytes)/1073741824.0, 2) || ' GB'
        WHEN sum(bytes) >= 1048576 THEN round(sum(bytes)/1048576.0, 2) || ' MB'
        WHEN sum(bytes) >= 1024 THEN round(sum(bytes)/1024.0, 2) || ' KB'
        ELSE sum(bytes) || ' B'
    END AS bytes_transferred
FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) 
${WHERE_SQL}
GROUP BY dstport 
ORDER BY flows DESC 
LIMIT 5;
"

    echo -e "\n${COLOR_BOLD}--- Protocol Breakdown ---${COLOR_RESET}"
    "${DUCKDB_CMD}" -box -c "
SELECT 
    CASE protocol 
        WHEN 1 THEN 'ICMP' 
        WHEN 2 THEN 'IGMP' 
        WHEN 6 THEN 'TCP' 
        WHEN 17 THEN 'UDP' 
        WHEN 41 THEN 'IPv6' 
        WHEN 47 THEN 'GRE' 
        WHEN 50 THEN 'ESP' 
        WHEN 58 THEN 'ICMPv6' 
        ELSE CAST(protocol AS VARCHAR) 
    END AS protocol, 
    count(*) AS flows, 
    sum(packets) AS packets, 
    CASE 
        WHEN sum(bytes) >= 1099511627776 THEN round(sum(bytes)/1099511627776.0, 2) || ' TB'
        WHEN sum(bytes) >= 1073741824 THEN round(sum(bytes)/1073741824.0, 2) || ' GB'
        WHEN sum(bytes) >= 1048576 THEN round(sum(bytes)/1048576.0, 2) || ' MB'
        WHEN sum(bytes) >= 1024 THEN round(sum(bytes)/1024.0, 2) || ' KB'
        ELSE sum(bytes) || ' B'
    END AS bytes
FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) 
${WHERE_SQL}
GROUP BY protocol 
ORDER BY flows DESC;
"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    exit 0
fi

# --- Sort and Limit ---
SORT_COL="start"
case "$(echo "${SORT}" | tr '[:upper:]' '[:lower:]')" in
    bytes)   SORT_COL="bytes" ;;
    packets) SORT_COL="packets" ;;
    src|srcaddr) SORT_COL="srcaddr" ;;
    dst|dstaddr) SORT_COL="dstaddr" ;;
    *)       SORT_COL="start" ;;
esac

ORDER_SQL="ORDER BY ${SORT_COL} ${ORDER}"
LIMIT_SQL=""
if [[ "${LIMIT}" -gt 0 ]]; then
    LIMIT_SQL="LIMIT ${LIMIT}"
fi

# --- Build Display Query ---
if [[ "${ALL_COLUMNS}" == "true" ]]; then
    QUERY_SQL="SELECT * FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) ${WHERE_SQL} ${ORDER_SQL} ${LIMIT_SQL};"
else
    SELECT_COLS="
    strftime(to_timestamp(start), '%Y-%m-%d %H:%M:%S') AS start_time,
    strftime(to_timestamp(columns('^end$')), '%Y-%m-%d %H:%M:%S') AS end_time,
    action,
    CASE protocol 
        WHEN 1 THEN 'ICMP' 
        WHEN 2 THEN 'IGMP' 
        WHEN 6 THEN 'TCP' 
        WHEN 17 THEN 'UDP' 
        WHEN 41 THEN 'IPv6' 
        WHEN 47 THEN 'GRE' 
        WHEN 50 THEN 'ESP' 
        WHEN 58 THEN 'ICMPv6' 
        ELSE CAST(protocol AS VARCHAR) 
    END AS proto,
    srcaddr || ':' || CAST(srcport AS VARCHAR) AS source,
    dstaddr || ':' || CAST(dstport AS VARCHAR) AS destination,
    packets,
    CASE 
        WHEN bytes >= 1099511627776 THEN round(bytes/1099511627776.0, 2) || ' TB'
        WHEN bytes >= 1073741824 THEN round(bytes/1073741824.0, 2) || ' GB'
        WHEN bytes >= 1048576 THEN round(bytes/1048576.0, 2) || ' MB'
        WHEN bytes >= 1024 THEN round(bytes/1024.0, 2) || ' KB'
        ELSE bytes || ' B'
    END AS bytes
"
    if [[ "${HAS_TCP_FLAGS}" -eq 1 ]]; then
        SELECT_COLS="${SELECT_COLS},
    CASE tcp_flags 
        WHEN 1 THEN 'FIN' 
        WHEN 2 THEN 'SYN' 
        WHEN 4 THEN 'RST' 
        WHEN 16 THEN 'ACK' 
        WHEN 18 THEN 'SYN-ACK' 
        WHEN 0 THEN '-' 
        ELSE CAST(tcp_flags AS VARCHAR) 
    END AS flags"
    fi

    if [[ "${HAS_FLOW_DIR}" -eq 1 ]]; then
        SELECT_COLS="${SELECT_COLS}, flow_direction AS dir"
    fi

    SELECT_COLS="${SELECT_COLS}, interface_id, log_status"

    if [[ "${HAS_VPC_ID}" -eq 1 ]]; then
        SELECT_COLS="${SELECT_COLS}, vpc_id"
    fi

    QUERY_SQL="SELECT ${SELECT_COLS} FROM read_parquet(${DUCKDB_EXPR}, union_by_name=true) ${WHERE_SQL} ${ORDER_SQL} ${LIMIT_SQL};"
fi

# --- Execute Query with Selected Format ---
DUCKDB_FORMAT_FLAG="-box"
case "$(echo "${FORMAT}" | tr '[:upper:]' '[:lower:]')" in
    table)
        DUCKDB_FORMAT_FLAG="-box"
        ;;
    detail|list)
        DUCKDB_FORMAT_FLAG="-line"
        ;;
    csv)
        DUCKDB_FORMAT_FLAG="-csv"
        ;;
    tsv)
        DUCKDB_FORMAT_FLAG="-tsv"
        ;;
    json)
        DUCKDB_FORMAT_FLAG="-json"
        ;;
    *)
        echo -e "${COLOR_YELLOW}[WARN] Unknown format '${FORMAT}', defaulting to table.${COLOR_RESET}" >&2
        DUCKDB_FORMAT_FLAG="-box"
        ;;
esac

echo -e "${COLOR_CYAN}[INFO] Scanning ${FILE_COUNT} Parquet file(s)...${COLOR_RESET}" >&2

# Colorized output filter for terminal table format
if [[ "${DUCKDB_FORMAT_FLAG}" == "-box" && -t 1 && "${NO_COLOR:-0}" -eq 0 ]]; then
    OUTPUT="$("${DUCKDB_CMD}" ${DUCKDB_FORMAT_FLAG} -c "${QUERY_SQL}")"
    # Highlight ACCEPT in green, REJECT in red
    COLORIZED_OUTPUT=$(echo "${OUTPUT}" | sed \
        -e "s/ACCEPT/$(printf "${COLOR_GREEN}ACCEPT${COLOR_RESET}")/g" \
        -e "s/REJECT/$(printf "${COLOR_RED}REJECT${COLOR_RESET}")/g" \
        -e "s/TCP/$(printf "${COLOR_CYAN}TCP${COLOR_RESET}")/g" \
        -e "s/UDP/$(printf "${COLOR_MAGENTA}UDP${COLOR_RESET}")/g" \
        -e "s/ICMP/$(printf "${COLOR_YELLOW}ICMP${COLOR_RESET}")/g" \
    )

    if [[ -n "${OUTFILE}" ]]; then
        echo "${OUTPUT}" > "${OUTFILE}"
        echo -e "${COLOR_GREEN}Output saved to: ${OUTFILE}${COLOR_RESET}" >&2
    fi

    echo "${COLORIZED_OUTPUT}"
else
    OUTPUT="$("${DUCKDB_CMD}" ${DUCKDB_FORMAT_FLAG} -c "${QUERY_SQL}")"
    if [[ -n "${OUTFILE}" ]]; then
        echo "${OUTPUT}" > "${OUTFILE}"
        echo -e "${COLOR_GREEN}Output saved to: ${OUTFILE}${COLOR_RESET}" >&2
    fi
    echo "${OUTPUT}"
fi

exit 0

# ==============================================================================
# BUNDLED ENGINE PAYLOAD
# ==============================================================================
__DUCKDB_PAYLOAD_START__
__EMBEDDED_PAYLOAD_PLACEHOLDER__
