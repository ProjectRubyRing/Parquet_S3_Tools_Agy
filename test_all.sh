#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " Running Automated Test Suite for view_vpc_flow_logs.sh"
echo "=========================================================="

test_count=0
pass_count=0

run_test() {
    local name="$1"
    shift
    test_count=$((test_count + 1))
    echo -e "\n[Test ${test_count}] ${name}"
    if "$@"; then
        echo -e "[PASS] ${name}"
        pass_count=$((pass_count + 1))
    else
        echo -e "[FAIL] ${name}" >&2
        exit 1
    fi
}

run_test "Single Parquet File Display" \
    ./view_vpc_flow_logs.sh ./test_data/single_sample.parquet

run_test "Directory Recursive Traversal (test_data/s3)" \
    ./view_vpc_flow_logs.sh ./test_data/s3

run_test "v2 Minimal Schema File (v2_only.parquet)" \
    ./view_vpc_flow_logs.sh ./test_data/v2_only.parquet

run_test "Filter by Action (--action REJECT)" \
    ./view_vpc_flow_logs.sh --action REJECT ./test_data/s3

run_test "Filter by Protocol (--protocol TCP)" \
    ./view_vpc_flow_logs.sh --protocol TCP ./test_data/s3

run_test "Filter by IP (--ip 10.0.1.25)" \
    ./view_vpc_flow_logs.sh --ip 10.0.1.25 ./test_data/s3

run_test "Summary Statistics Dashboard (--stats)" \
    ./view_vpc_flow_logs.sh --stats ./test_data/s3

run_test "Output Formats (csv, json, detail)" \
    bash -c './view_vpc_flow_logs.sh -f csv -l 1 ./test_data/s3 > /dev/null && ./view_vpc_flow_logs.sh -f json -l 1 ./test_data/s3 > /dev/null && ./view_vpc_flow_logs.sh -f detail -l 1 ./test_data/s3 > /dev/null'

run_test "Save to Output File (-o)" \
    bash -c 'rm -f test_out_sh.txt && ./view_vpc_flow_logs.sh -o test_out_sh.txt -l 2 ./test_data/s3 > /dev/null && test -s test_out_sh.txt && rm -f test_out_sh.txt'

run_test "Isolated Standalone Extraction Verification" \
    ./test_standalone_bash.sh

echo -e "\n=========================================================="
echo " ALL ${pass_count} / ${test_count} TESTS PASSED SUCCESSFULLY!"
echo "=========================================================="
