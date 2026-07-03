# VM Kernel Panic Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ACPI support to Raspberry Pi OS containerdisk by modifying boot configuration files in the build script, enabling VMs to boot successfully in KubeVirt on ARM64

**Architecture:** Modify `/boot/cmdline.txt` and `/boot/config.txt` in the guest filesystem during the build process to add `acpi=force no_timer_check` kernel parameters and disable conflicting graphics overlays. The changes are applied after mounting the guest filesystems and before converting the image.

**Tech Stack:** Bash, QEMU, KubeVirt, ARM64 ACPI, Raspberry Pi OS

## Global Constraints

- Target: Raspberry Pi OS Trixie ARM64 (2026-06-18 or newer)
- Platform: KubeVirt v1.8.3 on ARM64 k3s cluster
- Machine type: `virt-rhel9.8.0` with `acpi=on` and `gic-version=2`
- Kernel parameters must include `console=ttyAMA0,115200` for KubeVirt serial console
- Build script: `build-raspios-lite-containerdisk.sh`

---

### Task 1: Write unit tests for cmdline.txt and config.txt modifications

**Files:**
- Create: `tests/test_acpi_fix.sh`
- Modify: `build-raspios-lite-containerdisk.sh` (add test helper functions)

**Interfaces:**
- Consumes: None (new test file)
- Produces: `tests/test_acpi_fix.sh` - Test file for ACPI fix functions

- [ ] **Step 1: Create test file structure**

Create `tests/test_acpi_fix.sh` with test setup:

```bash
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
```

- [ ] **Step 2: Write test for cmdline.txt modifications**

Add test content:

```bash
test_cmdline_txt_modifications() {
  echo "Test 1: cmdline.txt modifications"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  
  # Create original cmdline.txt
  echo "console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize" > "${cmdline_file}"
  
  # Run the function
  modify_cmdline_txt "${TEST_BOOT_DIR}"
  
  local actual_content
  actual_content=$(cat "${cmdline_file}")
  
  # Verify all required elements are present
  if [[ "${actual_content}" != *console=ttyAMA0,115200* ]]; then
    echo "FAIL: console=ttyAMA0,115200 not found in cmdline.txt"
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
```

- [ ] **Step 3: Write test for config.txt modifications**

Add test content:

```bash
test_config_txt_modifications() {
  echo "Test 2: config.txt modifications"
  
  local config_file="${TEST_BOOT_DIR}/config.txt"
  
  # Create original config.txt with vc4-kms-v3d overlay
  cat > "${config_file}" << 'EOF'
[all]
dtoverlay=vc4-kms-v3d
EOF
  
  # Run the function
  modify_config_txt "${TEST_BOOT_DIR}"
  
  local actual_content
  actual_content=$(cat "${config_file}")
  
  # Verify vc4-kms-v3d is commented out
  if [[ "${actual_content}" != *"# dtoverlay=vc4-kms-v3d"* ]]; then
    echo "FAIL: dtoverlay=vc4-kms-v3d not commented out"
    return 1
  fi
  
  echo "PASS: config.txt modifications verified"
  return 0
}
```

- [ ] **Step 4: Write test for fallback cmdline**

Add test content:

```bash
test_fallback_cmdline_creation() {
  echo "Test 3: Fallback cmdline file creation"
  
  local cmdline_file="${TEST_BOOT_DIR}/cmdline.txt"
  local fallback_file="${TEST_BOOT_DIR}/cmdline_acpi_fallback.txt"
  
  # Create original cmdline.txt
  echo "console=ttyAMA0,115200 acpi=force no_timer_check root=PARTUUID=041bba91-02" > "${cmdline_file}"
  
  # Run the function
  create_fallback_cmdline "${TEST_BOOT_DIR}"
  
  if [[ ! -f "${fallback_file}" ]]; then
    echo "FAIL: Fallback cmdline file not created"
    return 1
  fi
  
  local fallback_content
  fallback_content=$(cat "${fallback_file}")
  
  if [[ "${fallback_content}" != *acpi=ht* ]]; then
    echo "FAIL: Fallback cmdline should contain acpi=ht"
    return 1
  fi
  
  echo "PASS: Fallback cmdline file creation verified"
  return 0
}
```

- [ ] **Step 5: Create main test runner**

Add test runner:

```bash
# Main test runner
main() {
  echo "=== ACPI Fix Unit Tests ==="
  echo ""
  
  local failed=0
  
  setup_test_env
  
  # Run tests
  test_cmdline_txt_modifications || failed=$((failed + 1))
  test_config_txt_modifications || failed=$((failed + 1))
  test_fallback_cmdline_creation || failed=$((failed + 1))
  
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
```

- [ ] **Step 6: Run test to verify it fails**

```bash
chmod +x tests/test_acpi_fix.sh
bash tests/test_acpi_fix.sh
```

Expected: All tests fail with "function not defined"

- [ ] **Step 7: Commit test file**

```bash
git add tests/test_acpi_fix.sh
git commit -m "test: add unit tests for ACPI fix"
```

---

### Task 2: Implement cmdline.txt and config.txt modifications in build script

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh` (add three functions)

**Interfaces:**
- Consumes: None
- Produces: `modify_cmdline_txt()`, `modify_config_txt()`, `create_fallback_cmdline()` functions

- [ ] **Step 1: Add modify_cmdline_txt function**

Add after the `run_guest_boot_sanity_checks()` function in `build-raspios-lite-containerdisk.sh`:

```bash
modify_cmdline_txt() {
    local boot_dir="$1"
    local cmdline_file="${boot_dir}/cmdline.txt"
    local fallback_file="${boot_dir}/cmdline_acpi_fallback.txt"
    
    if [[ ! -f "${cmdline_file}" ]]; then
        log_error "cmdline.txt not found at ${cmdline_file}"
        return 1
    fi
    
    # Read original cmdline
    local original_cmdline
    original_cmdline=$(cat "${cmdline_file}")
    
    # Remove old console parameters
    local modified_cmdline
    modified_cmdline=$(echo "${original_cmdline}" | sed 's/console=serial0,115200//g' | sed 's/console=tty1//g')
    
    # Add console=ttyAMA0,115200 at the beginning
    if [[ "${modified_cmdline}" != *"console=ttyAMA0,115200"* ]]; then
        modified_cmdline="console=ttyAMA0,115200 ${modified_cmdline}"
    fi
    
    # Add acpi=force no_timer_check if not already present
    if [[ "${modified_cmdline}" != *"acpi=force"* ]]; then
        modified_cmdline="${modified_cmdline} acpi=force"
    fi
    
    if [[ "${modified_cmdline}" != *"no_timer_check"* ]]; then
        modified_cmdline="${modified_cmdline} no_timer_check"
    fi
    
    # Trim multiple spaces to single space
    modified_cmdline=$(echo "${modified_cmdline}" | tr -s ' ')
    
    # Write modified cmdline
    echo "${modified_cmdline}" > "${cmdline_file}"
    
    # Create fallback cmdline with acpi=ht
    local fallback_cmdline
    fallback_cmdline=$(echo "${modified_cmdline}" | sed 's/acpi=force/acpi=ht/')
    echo "${fallback_cmdline}" > "${fallback_file}"
    
    log_info "cmdline.txt modified with ACPI support"
    log_info "Fallback cmdline created at cmdline_acpi_fallback.txt"
}
```

- [ ] **Step 2: Add modify_config_txt function**

Add after `modify_cmdline_txt()`:

```bash
modify_config_txt() {
    local boot_dir="$1"
    local config_file="${boot_dir}/config.txt"
    
    if [[ ! -f "${config_file}" ]]; then
        log_warn "config.txt not found at ${config_file}, skipping"
        return 0
    fi
    
    # Create backup
    cp "${config_file}" "${config_file}.bak"
    
    # Disable vc4-kms-v3d overlay by commenting it out
    sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "${config_file}"
    
    log_info "config.txt modified to disable vc4-kms-v3d overlay"
}
```

- [ ] **Step 3: Add create_fallback_cmdline function**

Add after `modify_config_txt()`:

```bash
create_fallback_cmdline() {
    local boot_dir="$1"
    local cmdline_file="${boot_dir}/cmdline.txt"
    local fallback_file="${boot_dir}/cmdline_acpi_fallback.txt"
    
    if [[ ! -f "${cmdline_file}" ]]; then
        log_error "cmdline.txt not found at ${cmdline_file}"
        return 1
    fi
    
    if [[ ! -f "${fallback_file}" ]]; then
        local original_cmdline
        original_cmdline=$(cat "${cmdline_file}")
        local fallback_cmdline
        fallback_cmdline=$(echo "${original_cmdline}" | sed 's/acpi=force/acpi=ht/')
        echo "${fallback_cmdline}" > "${fallback_file}"
        log_info "Fallback cmdline created at ${fallback_file}"
    fi
}
```

- [ ] **Step 4: Add helper logging functions**

Add these helper functions if not already present:

```bash
log_info() {
    echo "[INFO] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}
```

- [ ] **Step 5: Call modification functions in build flow**

Find the `main()` function and add the calls after `run_guest_boot_sanity_checks`:

```bash
main() {
  local image_tag="${IMAGE_TAG_OVERRIDE:-$(default_image_tag)}"

  validate_runtime_inputs
  validate_bootstrap_tools
  install_host_dependencies
  validate_host_tools
  download_source_image
  expand_and_map_image
  mount_guest_filesystems
  convert_guest_image
  run_guest_boot_sanity_checks
  
  # Apply ACPI fix after sanity checks
  modify_cmdline_txt "${GUEST_MOUNT_DIR}/boot/efi"
  modify_config_txt "${GUEST_MOUNT_DIR}/boot/efi"
  create_fallback_cmdline "${GUEST_MOUNT_DIR}/boot/efi"
  
  unmount_guest_filesystems || return 1
  convert_to_qcow2
  run_boot_smoke_validation
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}
```

- [ ] **Step 6: Run tests to verify implementation**

```bash
bash tests/test_acpi_fix.sh
```

Expected: All tests pass

- [ ] **Step 7: Commit implementation**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: add ACPI fix to build script"
```

---

### Task 3: Update documentation in README.md

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: None
- Produces: Updated documentation

- [ ] **Step 1: Add section about VM kernel panic fix**

Add after the "Features" section:

```markdown
### VM Kernel Panic Fix

This containerdisk includes fixes for running Raspberry Pi OS in KubeVirt on ARM64 nodes:

- **ACPI Support:** Added `acpi=force` kernel parameter to enable ACPI-based boot in KubeVirt VMs
- **Console Configuration:** Changed from `serial0` to `ttyAMA0` for proper serial console output
- **Timer Calibration:** Added `no_timer_check` to skip timer calibration that may fail in VMs
- **Graphics Overlay:** Disabled `vc4-kms-v3d` overlay that conflicts with VM graphics
- **Fallback:** Created `cmdline_acpi_fallback.txt` with `acpi=ht` for reduced ACPI functionality

If the primary boot with `acpi=force` fails, copy `cmdline_acpi_fallback.txt` to `cmdline.txt` to use the fallback configuration.
```

- [ ] **Step 2: Update Architecture section**

Update the "Architecture" section:

```markdown
### Architecture

The containerdisk is built from Raspberry Pi OS Trixie ARM64 minimal image. The build process:

1. Downloads and expands the source image
2. Mounts the boot partition (ESP) and root filesystem
3. Applies ACPI fix to enable KubeVirt compatibility (modifies cmdline.txt and config.txt)
4. Creates fallback cmdline file with acpi=ht
5. Runs boot sanity checks
6. Unmounts filesystems and converts to qcow2 format
7. Builds containerdisk Docker image

The ACPI fix modifies `/boot/cmdline.txt` to add kernel parameters required for ACPI-based boot in KubeVirt's `virt-rhel9.8.0` machine type, and disables the vc4-kms-v3d graphics overlay that conflicts with VM graphics.
```

- [ ] **Step 3: Add troubleshooting section**

Add before "Contributing":

```markdown
### Troubleshooting

#### VM Still Crashes with Kernel Panic

If your VM still crashes after applying this fix:

1. Check the VM's kernel logs using `kubectl logs <pod-name>`
2. Verify the containerdisk image tag is correct
3. Try using the fallback cmdline: Copy `cmdline_acpi_fallback.txt` to `cmdline.txt`
4. Ensure your KubeVirt VM configuration uses the correct machine type

#### Smoke Validation Fails

The smoke validation checks if the VM boots successfully. If it fails:

1. Check the VM's serial console output for kernel panic messages
2. Verify the containerdisk was built with the ACPI fix
3. Ensure your KubeVirt cluster has sufficient resources (at least 1GB RAM)
4. Try deploying with increased timeout in the VM manifest
```

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "docs: add VM kernel panic fix documentation"
```

---

### Task 4: Integration test and validation

**Files:**
- Create: `tests/test_integration.sh`
- Modify: `.github/workflows/build.yml` (if exists)

**Interfaces:**
- Consumes: `build-raspios-lite-containerdisk.sh` and `tests/test_acpi_fix.sh`
- Produces: Integration test results

- [ ] **Step 1: Create integration test script**

Create `tests/test_integration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/../build-raspios-lite-containerdisk.sh"

echo "Running unit tests..."
bash "${SCRIPT_DIR}/test_acpi_fix.sh"

echo ""
echo "Running integration tests..."

# Test 1: Verify build script source
if ! source "${BUILD_SCRIPT}" 2>/dev/null; then
    echo "FAIL: Cannot source build script"
    exit 1
fi
echo "PASS: Build script sources correctly"

# Test 2: Verify functions exist
if ! declare -f modify_cmdline_txt >/dev/null 2>&1; then
    echo "FAIL: modify_cmdline_txt not defined"
    exit 1
fi
if ! declare -f modify_config_txt >/dev/null 2>&1; then
    echo "FAIL: modify_config_txt not defined"
    exit 1
fi
if ! declare -f create_fallback_cmdline >/dev/null 2>&1; then
    echo "FAIL: create_fallback_cmdline not defined"
    exit 1
fi
echo "PASS: All modification functions are defined"

echo ""
echo "All integration tests passed!"
```

- [ ] **Step 2: Run integration tests**

```bash
chmod +x tests/test_integration.sh
bash tests/test_integration.sh
```

Expected: All tests pass

- [ ] **Step 3: Verify build script syntax**

```bash
bash -n build-raspios-lite-containerdisk.sh
```

Expected: No syntax errors

- [ ] **Step 4: Run unit tests again**

```bash
bash tests/test_acpi_fix.sh
```

Expected: All tests pass

- [ ] **Step 5: Final commit**

```bash
git add tests/test_integration.sh
git commit -m "test: add integration test suite"
```

---

## Self-Review

**1. Spec coverage:**

- [x] Add `acpi=force` to cmdline.txt - Task 2, Step 1
- [x] Change console from `serial0` to `ttyAMA0` - Task 2, Step 1
- [x] Add `no_timer_check` to cmdline.txt - Task 2, Step 1
- [x] Disable `dtoverlay=vc4-kms-v3d` in config.txt - Task 2, Step 2
- [x] Create fallback cmdline with `acpi=ht` - Task 2, Step 3
- [x] Run modifications after mount_guest_filesystems - Task 2, Step 5
- [x] Update documentation - Task 3
- [x] Add tests - Task 1, Task 4

**2. Placeholder scan:**

- No placeholders found in the plan

**3. Type consistency:**

- All functions use consistent naming: `modify_cmdline_txt`, `modify_config_txt`, `create_fallback_cmdline`
- Boot directory parameter is consistently `${boot_dir}` or `${BOOT_DIR}`
- Test file consistently uses `tests/test_acpi_fix.sh`

Plan complete and saved to `docs/superpowers/plans/2026-07-03-vm-kernel-panic-fix.md`.
