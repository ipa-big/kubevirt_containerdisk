# KubeVirt Startup Panic Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the dedicated Raspberry Pi containerdisk builder so the published image boots to a KubeVirt login prompt instead of panicking during startup.

**Architecture:** Keep the current fixed-image build flow and focus changes inside the dedicated builder path. Split the work into three parts: codify the boot contract in tests, harden the guest conversion plus artifact sanity checks, and add a lightweight boot smoke validation gate that runs before publish.

**Tech Stack:** Bash, qemu-img, qemu-system-aarch64, GRUB EFI, initramfs-tools, GitHub Actions, GHCR, KubeVirt containerdisk image layout

## Global Constraints

- Preserve the current build flow and apply only targeted boot fixes
- Keep the current fixed Raspberry Pi OS image target
- The output remains a KubeVirt containerdisk image
- Validation can be added, but it must stay lightweight
- The build still produces the expected KubeVirt containerdisk artifact
- The boot-critical guest configuration is explicit and internally consistent
- The build fails before publish if boot-critical sanity checks or validation fail
- A KubeVirt VM using the published containerdisk reaches a normal login prompt without startup issues

---

## File Structure

- Modify: `build-raspios-lite-containerdisk.sh` — add explicit boot-contract helpers, post-conversion sanity checks, and a lightweight boot smoke validator that runs before publish.
- Modify: `tests/build-raspios-lite-containerdisk.test.sh` — extend the bash regression harness so it covers boot-contract writes, sanity-check commands, smoke-test orchestration, and publish gating.
- Modify: `.github/workflows/main.yml` — keep validation on pull requests and manual runs, but ensure the workflow still exercises the builder with the new smoke validation path.
- Modify: `README.md` — document the new validation behavior and the startup-panic fix intent only where it affects operator usage.

### Task 1: Lock the boot contract into regression tests

**Files:**
- Modify: `tests/build-raspios-lite-containerdisk.test.sh`
- Modify: `build-raspios-lite-containerdisk.sh:175-281`

**Interfaces:**
- Consumes:
  - `convert_guest_image() -> exit 0`
  - `main() -> exit 0/1`
  - `default_image_tag() -> stdout string`
- Produces:
  - `run_guest_boot_sanity_checks() -> exit 0/1`
  - `run_boot_smoke_validation() -> exit 0/1`
  - `build_containerdisk_image(image_tag) -> exit 0`

- [ ] **Step 1: Write the failing test**

Append these tests just before the existing `echo "PASS"` line in `tests/build-raspios-lite-containerdisk.test.sh`:

```bash
test_convert_guest_image_writes_explicit_boot_contract() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  LOOP_DEVICE="/dev/loop7"

  local chroot_script=""
  sudo() {
    if [[ "$1" == "chroot" ]]; then
      shift 3
      chroot_script="$(cat)"
      return 0
    fi
  }
  log_step() { :; }

  convert_guest_image

  assert_contains "${chroot_script}" "apt-get install -qq -y linux-image-arm64 grub-efi-arm64"
  assert_contains "${chroot_script}" "grep -qxF 'virtio_blk' /etc/initramfs-tools/modules || echo 'virtio_blk' >> /etc/initramfs-tools/modules"
  assert_contains "${chroot_script}" "grep -qxF 'virtio_pci' /etc/initramfs-tools/modules || echo 'virtio_pci' >> /etc/initramfs-tools/modules"
  assert_contains "${chroot_script}" "grep -qxF 'virtio_net' /etc/initramfs-tools/modules || echo 'virtio_net' >> /etc/initramfs-tools/modules"
  assert_contains "${chroot_script}" 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyAMA0,115200 earlycon=pl011,0x09000000 rootwait"'
  assert_contains "${chroot_script}" "GRUB_DISABLE_LINUX_PARTUUID=true"
  assert_contains "${chroot_script}" "UUID=\$ROOT_UUID / ext4 defaults,noatime 0 1"
  assert_contains "${chroot_script}" "UUID=\$BOOT_UUID /boot/efi vfat defaults 0 2"
}

test_run_guest_boot_sanity_checks_verifies_kernel_initramfs_grub_and_fstab() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local chroot_calls=()
  sudo() {
    if [[ "$1" == "chroot" ]]; then
      chroot_calls+=("$4")
      return 0
    fi
  }
  log_step() { :; }

  run_guest_boot_sanity_checks

  assert_eq "${chroot_calls[*]}" "test test test grep grep"
}

test_main_runs_sanity_check_and_boot_validation_before_build() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export PUSH_IMAGE=false

  local calls=()
  validate_runtime_inputs() { calls+=("validate_runtime_inputs"); }
  validate_bootstrap_tools() { calls+=("validate_bootstrap_tools"); }
  install_host_dependencies() { calls+=("install_host_dependencies"); }
  validate_host_tools() { calls+=("validate_host_tools"); }
  download_source_image() { calls+=("download_source_image"); }
  expand_and_map_image() { calls+=("expand_and_map_image"); }
  mount_guest_filesystems() { calls+=("mount_guest_filesystems"); }
  convert_guest_image() { calls+=("convert_guest_image"); }
  run_guest_boot_sanity_checks() { calls+=("run_guest_boot_sanity_checks"); }
  unmount_guest_filesystems() { calls+=("unmount_guest_filesystems"); }
  convert_to_qcow2() { calls+=("convert_to_qcow2"); }
  run_boot_smoke_validation() { calls+=("run_boot_smoke_validation"); }
  build_containerdisk_image() { calls+=("build_containerdisk_image:$1"); }
  log_step() { :; }

  main

  assert_eq "${calls[*]}" "validate_runtime_inputs validate_bootstrap_tools install_host_dependencies validate_host_tools download_source_image expand_and_map_image mount_guest_filesystems convert_guest_image run_guest_boot_sanity_checks unmount_guest_filesystems convert_to_qcow2 run_boot_smoke_validation build_containerdisk_image:ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
  unset PUSH_IMAGE
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL with `run_guest_boot_sanity_checks: command not found`

- [ ] **Step 3: Write minimal implementation**

In `build-raspios-lite-containerdisk.sh`, add these stub functions immediately after `convert_guest_image()`:

```bash
run_guest_boot_sanity_checks() {
  log_step "Running guest boot sanity checks"
  sudo chroot "${ROOT_MOUNT_DIR}" test -f /boot/grub/grub.cfg
  sudo chroot "${ROOT_MOUNT_DIR}" test -d /boot/efi/EFI
  sudo chroot "${ROOT_MOUNT_DIR}" test -s /etc/fstab
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q 'GRUB_DISABLE_LINUX_PARTUUID=true' /etc/default/grub
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^UUID=.* /boot/efi vfat ' /etc/fstab
}

run_boot_smoke_validation() {
  log_step "Running lightweight boot smoke validation"
  return 0
}
```

Then update `main()` so it becomes:

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
  unmount_guest_filesystems || return 1
  convert_to_qcow2
  run_boot_smoke_validation
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && bash -n build-raspios-lite-containerdisk.sh`

Expected:
- `PASS` from the regression test script
- no output from `bash -n`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "test: lock boot contract into builder regression harness"
```

### Task 2: Harden guest conversion and sanity-check the converted image

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh`
- Modify: `tests/build-raspios-lite-containerdisk.test.sh`

**Interfaces:**
- Consumes:
  - `run_guest_boot_sanity_checks() -> exit 0/1`
  - `convert_guest_image() -> exit 0`
- Produces:
  - `run_guest_boot_sanity_checks() -> exit 0/1`
  - `convert_guest_image() -> exit 0`

- [ ] **Step 1: Write the failing test**

Replace the `run_guest_boot_sanity_checks` test from Task 1 with this fuller version:

```bash
test_run_guest_boot_sanity_checks_verifies_kernel_initramfs_grub_and_fstab() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local chroot_calls=()
  sudo() {
    if [[ "$1" == "chroot" ]]; then
      shift 2
      chroot_calls+=("$*")
      return 0
    fi
  }
  log_step() { :; }

  run_guest_boot_sanity_checks

  assert_eq "${chroot_calls[0]}" '/mnt/rpi_root test -f /boot/grub/grub.cfg'
  assert_eq "${chroot_calls[1]}" '/mnt/rpi_root test -d /boot/efi/EFI'
  assert_eq "${chroot_calls[2]}" '/mnt/rpi_root bash -lc ls /boot/initrd.img-* >/dev/null'
  assert_eq "${chroot_calls[3]}" '/mnt/rpi_root bash -lc ls /boot/vmlinuz-* >/dev/null'
  assert_eq "${chroot_calls[4]}" '/mnt/rpi_root grep -q GRUB_DISABLE_LINUX_PARTUUID=true /etc/default/grub'
  assert_eq "${chroot_calls[5]}" '/mnt/rpi_root grep -q ^UUID=.* / ext4 defaults,noatime 0 1$ /etc/fstab'
  assert_eq "${chroot_calls[6]}" '/mnt/rpi_root grep -q ^UUID=.* /boot/efi vfat defaults 0 2$ /etc/fstab'
  assert_eq "${chroot_calls[7]}" '/mnt/rpi_root grep -q ^virtio_blk$ /etc/initramfs-tools/modules'
  assert_eq "${chroot_calls[8]}" '/mnt/rpi_root grep -q ^virtio_pci$ /etc/initramfs-tools/modules'
  assert_eq "${chroot_calls[9]}" '/mnt/rpi_root grep -q ^virtio_net$ /etc/initramfs-tools/modules'
}
```

Also add this new test before `echo "PASS"`:

```bash
test_convert_guest_image_runs_update_initramfs_after_module_and_grub_changes() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  LOOP_DEVICE="/dev/loop7"

  local chroot_script=""
  sudo() {
    if [[ "$1" == "chroot" ]]; then
      shift 3
      chroot_script="$(cat)"
      return 0
    fi
  }
  log_step() { :; }

  convert_guest_image

  assert_contains "${chroot_script}" "update-initramfs -u -k all"
  assert_contains "${chroot_script}" "grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable"
  assert_contains "${chroot_script}" "update-grub"
  assert_contains "${chroot_script}" "ln -s efi /boot/firmware"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL because `run_guest_boot_sanity_checks` does not yet perform all required chroot checks

- [ ] **Step 3: Write minimal implementation**

Replace `run_guest_boot_sanity_checks()` in `build-raspios-lite-containerdisk.sh` with:

```bash
run_guest_boot_sanity_checks() {
  log_step "Running guest boot sanity checks"
  sudo chroot "${ROOT_MOUNT_DIR}" test -f /boot/grub/grub.cfg
  sudo chroot "${ROOT_MOUNT_DIR}" test -d /boot/efi/EFI
  sudo chroot "${ROOT_MOUNT_DIR}" bash -lc 'ls /boot/initrd.img-* >/dev/null'
  sudo chroot "${ROOT_MOUNT_DIR}" bash -lc 'ls /boot/vmlinuz-* >/dev/null'
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q 'GRUB_DISABLE_LINUX_PARTUUID=true' /etc/default/grub
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^UUID=.* / ext4 defaults,noatime 0 1$' /etc/fstab
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^UUID=.* /boot/efi vfat defaults 0 2$' /etc/fstab
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_blk$' /etc/initramfs-tools/modules
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_pci$' /etc/initramfs-tools/modules
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_net$' /etc/initramfs-tools/modules
}
```

Keep `convert_guest_image()` in the existing shape, but if the current file has drifted, make sure it still contains exactly these boot-critical commands:

```bash
grep -qxF 'virtio' /etc/initramfs-tools/modules || echo 'virtio' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_blk' /etc/initramfs-tools/modules || echo 'virtio_blk' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_pci' /etc/initramfs-tools/modules || echo 'virtio_pci' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_net' /etc/initramfs-tools/modules || echo 'virtio_net' >> /etc/initramfs-tools/modules
update-initramfs -u -k all
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
update-grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyAMA0,115200 earlycon=pl011,0x09000000 rootwait"/' /etc/default/grub
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && bash -n build-raspios-lite-containerdisk.sh`

Expected:
- `PASS`
- no output from `bash -n`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "feat: add explicit KubeVirt boot sanity checks"
```

### Task 3: Add lightweight boot smoke validation and gate publish on it

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh`
- Modify: `tests/build-raspios-lite-containerdisk.test.sh`
- Modify: `.github/workflows/main.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes:
  - `validate_bootstrap_tools() -> exit 0/1`
  - `validate_host_tools() -> exit 0/1`
  - `run_guest_boot_sanity_checks() -> exit 0/1`
  - `convert_to_qcow2() -> exit 0`
- Produces:
  - `run_boot_smoke_validation() -> exit 0/1`
  - `BOOT_SMOKE_TIMEOUT_SECONDS` readonly constant
  - workflow validation path that executes the smoke-gated builder with `PUSH_IMAGE='false'`

- [ ] **Step 1: Write the failing test**

Add these tests before `echo "PASS"` in `tests/build-raspios-lite-containerdisk.test.sh`:

```bash
test_validate_host_tools_requires_qemu_system_for_smoke_validation() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local commands=()
  validate_bootstrap_tools() { :; }
  require_command() { commands+=("$1"); }

  validate_host_tools

  assert_contains "${commands[*]}" "qemu-system-aarch64"
  assert_contains "${commands[*]}" "timeout"
}

test_run_boot_smoke_validation_uses_serial_login_probe() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local timeout_args=""
  local qemu_args=""
  timeout() {
    timeout_args="$*"
    shift 2
    "$@"
  }
  qemu-system-aarch64() {
    qemu_args="$*"
    printf 'Debian GNU/Linux 13 raspberrypi ttyAMA0\nraspberrypi login: \n'
  }
  log_step() { :; }

  run_boot_smoke_validation

  assert_contains "${timeout_args}" "${BOOT_SMOKE_TIMEOUT_SECONDS}"
  assert_contains "${qemu_args}" "-M virt"
  assert_contains "${qemu_args}" "-cpu cortex-a72"
  assert_contains "${qemu_args}" "-serial mon:stdio"
  assert_contains "${qemu_args}" "-drive file=disc.qcow2,if=virtio,format=qcow2"
}

test_workflow_validation_job_runs_builder_with_push_disabled() {
  local validate_job
  validate_job="$(extract_job_block "validate-raspberry-pi-containerdisk")"

  assert_contains "${validate_job}" "PUSH_IMAGE: 'false'"
  assert_contains "${validate_job}" "run: bash ./build-raspios-lite-containerdisk.sh"
}

test_readme_documents_boot_validation() {
  local readme
  readme="$(<"${ROOT_DIR}/README.md")"

  assert_contains "${readme}" "The script runs a lightweight boot smoke validation before publishing."
  assert_contains "${readme}" "Set \`PUSH_IMAGE=false\` to validate the build without publishing"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL because `validate_host_tools` does not yet require `qemu-system-aarch64`, and `run_boot_smoke_validation` is still a stub

- [ ] **Step 3: Write minimal implementation**

In `build-raspios-lite-containerdisk.sh`, add this fixed constant near the other readonly constants:

```bash
set_fixed_constant BOOT_SMOKE_TIMEOUT_SECONDS "180"
```

Update `validate_host_tools()` to include the lightweight validation commands:

```bash
for cmd in e2fsck growpart kpartx parted qemu-aarch64-static qemu-img qemu-system-aarch64 resize2fs sha256sum timeout wget xz; do
  require_command "${cmd}" || return 1
done
```

Replace `run_boot_smoke_validation()` with:

```bash
run_boot_smoke_validation() {
  log_step "Running lightweight boot smoke validation"

  local boot_output=""
  boot_output="$(
    timeout "${BOOT_SMOKE_TIMEOUT_SECONDS}" \
      qemu-system-aarch64 \
        -M virt \
        -cpu cortex-a72 \
        -m 2048 \
        -nographic \
        -serial mon:stdio \
        -drive "file=disc.qcow2,if=virtio,format=qcow2"
  )" || {
    printf '%s\n' "${boot_output}" >&2
    echo "Error: boot smoke validation did not reach a login prompt." >&2
    return 1
  }

  if [[ "${boot_output}" != *"login:"* ]]; then
    printf '%s\n' "${boot_output}" >&2
    echo "Error: boot smoke validation did not reach a login prompt." >&2
    return 1
  fi
}
```

Update the validation section of `README.md` so it includes this exact sentence after the local validation example:

```markdown
The script runs a lightweight boot smoke validation before publishing.
```

Keep `.github/workflows/main.yml` on the existing dedicated builder path, but ensure the validation job still runs:

```yaml
  validate-raspberry-pi-containerdisk:
    if: github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && bash -n build-raspios-lite-containerdisk.sh && grep -n "validate-raspberry-pi-containerdisk" .github/workflows/main.yml`

Expected:
- `PASS`
- no output from `bash -n`
- one grep match for `validate-raspberry-pi-containerdisk`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh .github/workflows/main.yml README.md
git commit -m "feat: gate containerdisk publish on boot smoke validation"
```
