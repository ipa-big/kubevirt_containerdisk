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

### Task 1: Implement cmdline.txt and config.txt modifications in build script

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh` (add `apply_acpi_fix` function)

**Interfaces:**
- Consumes: None
- Produces: `apply_acpi_fix()` function

- [ ] **Step 1: Add apply_acpi_fix function**

Add after the `run_guest_boot_sanity_checks()` function in `build-raspios-lite-containerdisk.sh`:

```bash
apply_acpi_fix() {
  log_step "Applying ACPI fix to guest filesystem"

  local boot_dir="${EFI_MOUNT_DIR}"

  # Modify cmdline.txt
  local cmdline_file="${boot_dir}/cmdline.txt"
  local fallback_file="${boot_dir}/cmdline_acpi_fallback.txt"

  if [[ -f "${cmdline_file}" ]]; then
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

    log_step "cmdline.txt modified with ACPI support"
    log_step "Fallback cmdline created at cmdline_acpi_fallback.txt"
  else
    echo "Warning: cmdline.txt not found at ${cmdline_file}" >&2
  fi

  # Modify config.txt to disable graphics overlay
  local config_file="${boot_dir}/config.txt"

  if [[ -f "${config_file}" ]]; then
    cp "${config_file}" "${config_file}.bak"
    sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "${config_file}"
    log_step "config.txt modified to disable vc4-kms-v3d overlay"
  else
    echo "Warning: config.txt not found at ${config_file}" >&2
  fi
}
```

- [ ] **Step 2: Call apply_acpi_fix in main function**

Find the `main()` function and add the call after `run_guest_boot_sanity_checks`:

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
  apply_acpi_fix
  unmount_guest_filesystems || return 1
  convert_to_qcow2
  run_boot_smoke_validation
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}
```

- [ ] **Step 3: Verify build script syntax**

```bash
bash -n build-raspios-lite-containerdisk.sh
```

Expected: No syntax errors

- [ ] **Step 4: Commit implementation**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: add ACPI fix to build script"
```

---

### Task 2: Update documentation in README.md

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: None
- Produces: Updated documentation

- [ ] **Step 1: Add VM Kernel Panic Fix section**

Add after the "## Raspberry Pi OS containerdisk build" section:

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

- [ ] **Step 2: Add troubleshooting section**

Add before "## References":

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

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: add VM kernel panic fix documentation"
```

---

## Self-Review

**1. Spec coverage:**

- [x] Add `acpi=force` to cmdline.txt - Task 1, Step 1
- [x] Change console from `serial0` to `ttyAMA0` - Task 1, Step 1
- [x] Add `no_timer_check` to cmdline.txt - Task 1, Step 1
- [x] Disable `dtoverlay=vc4-kms-v3d` in config.txt - Task 1, Step 1
- [x] Create fallback cmdline with `acpi=ht` - Task 1, Step 1
- [x] Run modifications after mount_guest_filesystems - Task 1, Step 2
- [x] Update documentation - Task 2

**2. Placeholder scan:**

- No placeholders found in the plan

**3. Type consistency:**

- Function name `apply_acpi_fix` used consistently
- Boot directory parameter uses `${boot_dir}` or `${EFI_MOUNT_DIR}`

Plan complete and saved to `docs/superpowers/plans/2026-07-03-vm-kernel-panic-fix.md`.
