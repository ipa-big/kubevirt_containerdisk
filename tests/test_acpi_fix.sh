#!/usr/bin/env bash
set -euo pipefail

# Test file for ACPI fix functions
# Tests for cmdline.txt and config.txt modifications

# Test setup
TEST_DIR=""
TEST_BOOT_DIR=""

setup_test_env() {
  TEST_DIR=$(mktemp -d)
  TEST_BOOT_DIR="${TEST_DIR}/boot"
  mkdir -p "${TEST_BOOT_DIR}"
}

cleanup_test_env() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
}

# Set up cleanup trap
trap cleanup_test_env EXIT

# Test 1: cmdline.txt modifications
test_cmdline_txt_modifications() {
  echo "Test 1: cmdline.txt modifications"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  
  # Create original cmdline.txt
  echo "console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize" > "${cmdline_file}"
  
  # Expected content after modifications
  local expected_content="console=ttyAMA0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait acpi=force no_timer_check"
  
  # Check if modify_cmdline_txt function exists and works
  if ! declare -f modify_cmdline_txt >/dev/null 2>&1; then
    echo "FAIL: modify_cmdline_txt function not defined"
    return 1
  fi
  
  modify_cmdline_txt "${TEST_BOOT_DIR}"
  
  local actual_content
  actual_content=$(cat "${cmdline_file}")
  
  # Verify all required elements are present
  if [[ "${actual_content}" != *console=ttyAMA0,115200* ]]; then
    echo "FAIL: console=ttyAMA0,115200 not found in cmdline.txt"
    echo "Expected: ${expected_content}"
    echo "Got: ${actual_content}"
    return 1
  fi
  
  if [[ "${actual_content}" != *acpi=force* ]]; then
    echo "FAIL: acpi=force not found in cmdline.txt"
    return 1
  fi
  
  if [[ "${actual_content}" != *no_timer_check* ]]; then
    echo "FAIL: no_timer_check not found in cmdline.txt"
    return 1
  fi
  
  echo "PASS: cmdline.txt modifications verified"
  return 0
}

# Test 2: config.txt modifications
test_config_txt_modifications() {
  echo "Test 2: config.txt modifications"
  
  local config_file="${TEST_BOOT_DIR}/config.txt"
  
  # Create original config.txt with vc4-kms-v3d overlay
  cat > "${config_file}" << 'EOF'
# Don't have the firmware create an initial video= setting in cmdline.txt.
#dtparam=audio=on

[pi4]
#dtoverlay=vc4-fkms-v3d
max_framebuffers=2

[all]
dtoverlay=vc4-kms-v3d
EOF
  
  # Check if modify_config_txt function exists and works
  if ! declare -f modify_config_txt >/dev/null 2>&1; then
    echo "FAIL: modify_config_txt function not defined"
    return 1
  fi
  
  modify_config_txt "${TEST_BOOT_DIR}"
  
  local actual_content
  actual_content=$(cat "${config_file}")
  
  # Verify vc4-kms-v3d is commented out
  if [[ "${actual_content}" != *"dtoverlay=vc4-kms-v3d"* ]]; then
    echo "FAIL: dtoverlay=vc4-kms-v3d still present (should be commented out)"
    echo "Got: ${actual_content}"
    return 1
  fi
  
  if [[ "${actual_content}" != *"# dtoverlay=vc4-kms-v3d"* ]]; then
    echo "FAIL: dtoverlay=vc4-kms-v3d not commented out properly"
    echo "Got: ${actual_content}"
    return 1
  fi
  
  echo "PASS: config.txt modifications verified"
  return 0
}

# Test 3: Fallback cmdline file creation
test_fallback_cmdline_creation() {
  echo "Test 3: Fallback cmdline file creation"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  local fallback_file="${TEST_BOOT_DIR}/cmdline_acpi_fallback.txt"
  
  # Create original cmdline.txt
  echo "console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait acpi=force no_timer_check" > "${cmdline_file}"
  
  # Check if create_fallback_cmdline function exists and works
  if ! declare -f create_fallback_cmdline >/dev/null 2>&1; then
    echo "FAIL: create_fallback_cmdline function not defined"
    return 1
  fi
  
  create_fallback_cmdline "${TEST_BOOT_DIR}"
  
  if [[ ! -f "${fallback_file}" ]]; then
    echo "FAIL: Fallback cmdline file not created"
    return 1
  fi
  
  local fallback_content
  fallback_content=$(cat "${fallback_file}")
  
  if [[ "${fallback_content}" != *acpi=ht* ]]; then
    echo "FAIL: Fallback cmdline should contain acpi=ht"
    echo "Got: ${fallback_content}"
    return 1
  fi
  
  echo "PASS: Fallback cmdline file creation verified"
  return 0
}

# Main test runner
main() {
  echo "=== ACPI Fix Unit Tests ==="
  echo ""
  
  local failed=0
  
  setup_test_env
  
  # Run tests
  test_cmdline_txt_modifications || ((failed++))
  test_config_txt_modifications || ((failed++))
  test_fallback_cmdline_creation || ((failed++))
  
  echo ""
  if [[ ${failed} -gt 0 ]]; then
    echo "=== TEST RESULTS: ${failed} tests failed ==="
    exit 1
  else
    echo "=== TEST RESULTS: All tests passed ==="
    exit 0
  fi
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi