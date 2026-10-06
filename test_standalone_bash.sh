#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " Running Isolated Standalone Verification Test for RHEL/Linux"
echo "=========================================================="

# 1. Create a isolated temp directory
TEST_DIR=$(mktemp -d /tmp/vpc_test_XXXXXX)
echo "[Step 1] Isolated directory created: ${TEST_DIR}"

# 2. Copy ONLY view_vpc_flow_logs.sh (NO bin/ directory, NO dependencies)
cp ./view_vpc_flow_logs.sh "${TEST_DIR}/view_vpc_flow_logs.sh"
chmod +x "${TEST_DIR}/view_vpc_flow_logs.sh"
echo "[Step 2] Standalone script copied to isolated directory."

# 3. Purge ~/.cache/vpc_flow_logs to ensure cold start
rm -rf ~/.cache/vpc_flow_logs
echo "[Step 3] Cache cleared. Engine must self-extract."

# 4. Execute standalone script on single parquet file
echo "[Step 4] Executing standalone script on test file..."
"${TEST_DIR}/view_vpc_flow_logs.sh" ./test_data/single_sample.parquet

# 5. Verify the engine was extracted to ~/.cache/vpc_flow_logs/duckdb
if [[ -x ~/.cache/vpc_flow_logs/duckdb ]]; then
    echo "[Step 5] PASS: Bundled engine was automatically extracted and verified: $(ls -lh ~/.cache/vpc_flow_logs/duckdb | awk '{print $5, $9}')"
else
    echo "[Step 5] FAIL: Bundled engine was not extracted!"
    exit 1
fi

# 6. Test directory recursion
echo "[Step 6] Testing recursive directory processing..."
"${TEST_DIR}/view_vpc_flow_logs.sh" ./test_data/s3

# 7. Test summary stats
echo "[Step 7] Testing summary stats mode..."
"${TEST_DIR}/view_vpc_flow_logs.sh" --stats ./test_data/s3

# Clean up
rm -rf "${TEST_DIR}"
echo "=========================================================="
echo " Standalone Bundled Verification SUCCESSFUL!"
echo "=========================================================="
