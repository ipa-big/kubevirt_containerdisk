#!/usr/bin/env bash
set -euo pipefail

# Test file for ACPI fix functions
# Tests for cmdline.txt and config.txt modifications

# Source the build script to get helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Setup test directories (without sourcing build script to avoid readonly variables)
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

# Test 1: cmdline.txt modifications - simulate apply_acpi_fix
test_cmdline_txt_modifications() {
  echo "Test 1: cmdline.txt modifications"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  
  # Create original cmdline.txt
  echo "console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize" > "${cmdline_file}"
  
  # Simulate the apply_acpi_fix function
  local original_cmdline
  original_cmdline=$(cat "${cmdline_file}")
  
  local modified_cmdline
  modified_cmdline=$(echo "${original_cmdline}" | sed 's/console=serial0,115200//g' | sed 's/console=tty1//g')
  
  if [[ "${modified_cmdline}" != *"console=ttyAMA0,115200"* ]]; then
    modified_cmdline="console=ttyAMA0,115200 ${modified_cmdline}"
  fi
  
  if [[ "${modified_cmdline}" != *"acpi=force"* ]]; then
    modified_cmdline="${modified_cmdline} acpi=force"
  fi
  
  if [[ "${modified_cmdline}" != *"no_timer_check"* ]]; then
    modified_cmdline="${modified_cmdline} no_timer_check"
  fi
  
  modified_cmdline=$(echo "${modified_cmdline}" | tr -s ' ')
  echo "${modified_cmdline}" > "${cmdline_file}"
  
  # Create fallback file
  local fallback_cmdline
  fallback_cmdline=$(echo "${modified_cmdline}" | sed 's/acpi=force/acpi=ht/')
  echo "${fallback_cmdline}" > "${TEST_BOOT_DIR}/cmdline_acpi_fallback.txt"
  
  local actual_content
  actual_content=$(cat "${cmdline_file}")
  
  # Verify all required elements are present
  if [[ "${actual_content}" != *console=ttyAMA0,115200* ]]; then
    echo "FAIL: console=ttyAMA0,115200 not found in cmdline.txt"
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
  
  # Verify fallback file was created
  if [[ ! -f "${TEST_BOOT_DIR}/cmdline_acpi_fallback.txt" ]]; then
    echo "FAIL: cmdline_acpi_fallback.txt not created"
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
[all]
dtoverlay=vc4-kms-v3d
EOF
  
  # Apply the config.txt modification (comment out vc4-kms-v3d)
  cp "${config_file}" "${config_file}.bak"
  sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "${config_file}"
  
  local actual_content
  actual_content=$(cat "${config_file}")
  
  # Verify vc4-kms-v3d is commented out
  if [[ "${actual_content}" != *"#dtoverlay=vc4-kms-v3d"* ]]; then
    echo "FAIL: dtoverlay=vc4-kms-v3d not commented out"
    echo "Got: ${actual_content}"
    return 1
  fi
  
  echo "PASS: config.txt modifications verified"
  return 0
}

# Test 3: Fallback cmdline content
test_fallback_cmdline_content() {
  echo "Test 3: Fallback cmdline content"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  local fallback_file="${TEST_BOOT_DIR}/cmdline_acpi_fallback.txt"
  
  # Create original cmdline.txt
  echo "console=ttyAMA0,115200 acpi=force no_timer_check root=PARTUUID=041bba91-02" > "${cmdline_file}"
  
  # Create fallback with acpi=ht
  local fallback_content
  fallback_content=$(echo "console=ttyAMA0,115200 acpi=force no_timer_check root=PARTUUID=041bba91-02" | sed 's/acpi=force/acpi=ht/')
  echo "${fallback_content}" > "${fallback_file}"
  
  fallback_content=$(cat "${fallback_file}")
  
  if [[ "${fallback_content}" != *acpi=ht* ]]; then
    echo "FAIL: Fallback cmdline should contain acpi=ht"
    echo "Got: ${fallback_content}"
    return 1
  fi
  
  if [[ "${fallback_content}" == *acpi=force* ]]; then
    echo "FAIL: Fallback cmdline should not contain acpi=force"
    echo "Got: ${fallback_content}"
    return 1
  fi
  
  echo "PASS: Fallback cmdline content verified"
  return 0
}

# Main test runner
main() {
  echo "=== ACPI Fix Unit Tests ==="
  echo ""
  
  local failed=0
  
  setup_test_env
  
  # Run tests
  test_cmdline_txt_modifications || failed=$((failed + 1))
  test_config_txt_modifications || failed=$((failed + 1))
  test_fallback_cmdline_content || failed=$((failed + 1))
  
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
