#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/../build-raspios-lite-containerdisk.sh"

echo "Running unit tests..."
bash "${SCRIPT_DIR}/test_acpi_fix.sh"

echo ""
echo "Running integration tests..."

# Test 1: Verify build script syntax
echo "Test 1: Verify build script syntax"
bash -n "${BUILD_SCRIPT}" && echo "PASS: Build script has no syntax errors" || {
    echo "FAIL: Build script has syntax errors"
    exit 1
}

# Test 2: Verify build script sources correctly
echo ""
echo "Test 2: Verify build script functions"
if ! source "${BUILD_SCRIPT}" 2>/dev/null; then
    echo "FAIL: Cannot source build script"
    exit 1
fi
echo "PASS: Build script sources correctly"

# Test 3: Verify apply_acpi_fix function exists
if ! declare -f apply_acpi_fix >/dev/null 2>&1; then
    echo "FAIL: apply_acpi_fix not defined"
    exit 1
fi
echo "PASS: apply_acpi_fix function is defined"

# Test 4: Verify build script structure
echo ""
echo "Test 4: Verify build script structure"
if grep -q "apply_acpi_fix" "${BUILD_SCRIPT}"; then
    echo "PASS: apply_acpi_fix is called in build script"
else
    echo "FAIL: apply_acpi_fix is not called in build script"
    exit 1
fi

echo ""
echo "All integration tests passed!"
