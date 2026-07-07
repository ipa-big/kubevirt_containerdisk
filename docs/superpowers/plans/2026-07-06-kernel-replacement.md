# VM Kernel Replacement with Generic ARM64 and SSH

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Raspberry Pi-specific kernel with a generic ARM64 kernel, install SSH server, and configure VMs to use physical-net network for integration testing

**Architecture:** The build script will install linux-image-arm64, remove all RPi kernel packages and files, configure GRUB to boot the generic kernel without ACPI parameters, install openssh-server, and verify the kernel is correctly installed. Integration tests will use the physical-net network.

**Tech Stack:** Bash, Debian packages, GRUB, initramfs-tools, KubeVirt, Multus CNI

## Global Constraints

- Target kernel: `linux-image-arm64` (provides generic ARM64 kernel, e.g., 6.12.95+deb13-arm64)
- Container disk image: `ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi`
- KubeVirt nodes: 3 arm64 (k3s-node-4, 5, 6) and 3 amd64
- Network: physical-net (Multus network attachment to bridge br0)
- Kernel must support virtio devices for containerDisk
- SSH server must be installed for remote access
- No kernel panic on VM boot
- Integration tests use physical-net network

---
### Task 1: Install SSH server with generic kernel

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:212-215`

**Interfaces:**
- Consumes: Current chroot environment with RPi kernel installed
- Produces: Chroot with generic kernel and SSH server installed

- [ ] **Step 1: Update apt-get install to include SSH server**

Replace lines 212-213:

```bash
apt-get update -qq
apt-get install -qq -y --no-install-recommends linux-image-arm64 grub-efi-arm64 openssh-server
```

- [ ] **Step 2: Run test to verify SSH installed**

Build with `PUSH_IMAGE=false` and check chroot:

```bash
bash -c 'source build-raspios-lite-containerdisk.sh'
# After convert_guest_image, verify:
sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep -q '^ii.*openssh-server'
```

Expected: `openssh-server` package is installed

- [ ] **Step 3: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: install openssh-server with generic kernel"
```

---

### Task 2: Update kernel cleanup to remove RPi kernels and verify

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:216-225`

**Interfaces:**
- Consumes: Chroot with generic kernel installed
- Produces: Clean chroot with only generic ARM64 kernel

- [ ] **Step 1: Verify RPi kernel removal commands**

Current state (lines 216-218):
```bash
# Remove Raspberry Pi kernel packages and their files
apt-get remove -y --purge linux-image-6.18.34+rpt-rpi-v8 linux-image-rpi-v8 linux-image-rpi-2712 || true
apt-get autoremove -y --purge || true
```

These commands should be kept as-is.

- [ ] **Step 2: Add verification after kernel removal**

After line 218, add:

```bash
# Verify no RPi kernel packages remain
if sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep -qE 'linux-image-(6\.18\.34\+rpt-rpi|linux-image-rpi)'; then
  log_fail "RPi kernel packages still installed"
  exit 1
fi
log_step "RPi kernel packages successfully removed"
```

- [ ] **Step 3: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: verify RPi kernel removal"
```

---

### Task 3: Remove ACPI fix and update GRUB for generic kernel

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:283-325`
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:424`

**Interfaces:**
- Consumes: GRUB configuration in chroot
- Produces: GRUB configured for generic kernel without ACPI parameters

- [ ] **Step 1: Remove apply_acpi_fix function**

Delete the entire `apply_acpi_fix()` function (lines 283-325) which:
- Modifies cmdline.txt with ACPI parameters
- Creates cmdline_acpi_fallback.txt
- Disables vc4-kms-v3d overlay

These are not needed with generic kernel.

- [ ] **Step 2: Remove apply_acpi_fix call in main**

Find and remove the line `apply_acpi_fix` from the `main()` function.

- [ ] **Step 3: Update GRUB cmdline for generic kernel**

Replace line 234:

```bash
# Use generic kernel cmdline without ACPI parameters
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyAMA0,115200 earlycon=pl011,0x09000000 rootwait"/' /etc/default/grub
```

- [ ] **Step 4: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: remove ACPI fix, use generic kernel without ACPI params"
```

---

### Task 4: Update initramfs generation for generic kernel

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:229`

**Interfaces:**
- Consumes: Generic kernel installed
- Produces: Initramfs generated for generic kernel

- [ ] **Step 1: Update initramfs generation**

Replace line 229:

```bash
# Generate initramfs for the generic ARM64 kernel only
update-initramfs -c -k all
```

- [ ] **Step 2: Verify initramfs created**

After build, check:

```bash
ls -lh /boot/initrd.img-*
# Should show initramfs for generic kernel (e.g., 6.12.95+deb13-arm64)
```

- [ ] **Step 3: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: generate initramfs for generic kernel"
```

---

### Task 5: Update verification checks for generic kernel

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:267-282`

**Interfaces:**
- Consumes: Modified build script
- Produces: Verification that generic kernel is in use

- [ ] **Step 1: Update run_guest_boot_sanity_checks**

Update lines 267-282:

```bash
run_guest_boot_sanity_checks() {
  log_step "Running guest boot sanity checks"
  sudo chroot "${ROOT_MOUNT_DIR}" test -f /boot/grub/grub.cfg
  sudo chroot "${ROOT_MOUNT_DIR}" test -d /boot/efi/EFI
  sudo chroot "${ROOT_MOUNT_DIR}" bash -lc 'ls /boot/initrd.img-* >/dev/null'
  sudo chroot "${ROOT_MOUNT_DIR}" bash -lc 'ls /boot/vmlinuz-* >/dev/null'
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q GRUB_DISABLE_LINUX_PARTUUID=true /etc/default/grub
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^UUID=.* / ext4 defaults,noatime 0 1$' /etc/fstab
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^UUID=.* /boot/efi vfat defaults 0 2$' /etc/fstab
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_blk$' /etc/initramfs-tools/modules
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_pci$' /etc/initramfs-tools/modules
  sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_net$' /etc/initramfs-tools/modules
  # Verify generic kernel is installed
  sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep 'linux-image-6\.12\.95\+deb13-arm64' | grep -q '^ii'
}
```

- [ ] **Step 2: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "test: update sanity checks for generic kernel"
```

---

### Task 6: Test build end-to-end

**Files:**
- Test: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh`
- Test: `/home/operation/kubevirt_containerdisk/tests/vm-integration-test-refactored.sh`

**Interfaces:**
- Consumes: Modified build script
- Produces: Working containerdisk image

- [ ] **Step 1: Build without pushing**

```bash
export PUSH_IMAGE=false
bash ./build-raspios-lite-containerdisk.sh
# Verify no errors
ls -la disc.qcow2
```

Expected: Build completes without errors, disc.qcow2 created

- [ ] **Step 2: Verify kernel version in image**

Extract and check:

```bash
# Use docker to extract and check
docker create --platform linux/arm64 --name kernel-check ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi:latest 2>/dev/null || true
docker run --rm --platform linux/arm64 --entrypoint /bin/bash ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi:latest -c "cat /proc/version" 2>/dev/null
```

Expected: Output shows `6.12.95+deb13-arm64` or similar generic kernel

- [ ] **Step 3: Test boot in KubeVirt**

```bash
bash tests/vm-integration-test-refactored.sh
```

Expected: VM boots, SSH accessible, no kernel panic

- [ ] **Step 4: Verify kernel version in running VM**

```bash
kubectl exec -it pod/virt-launcher-raspi-test-integration-* -c compute -- /bin/bash -c "cat /proc/version"
```

Expected: Output shows generic kernel version

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "test: verify generic kernel works in KubeVirt"
```

---

### Task 7: Update documentation

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/README.md`

**Interfaces:**
- Consumes: Updated behavior
- Produces: Correct documentation

- [ ] **Step 1: Update VM Kernel Panic Fix section**

Replace lines 7-15:

```markdown
### VM Kernel Panic Fix

This containerdisk uses a generic ARM64 kernel instead of the Raspberry Pi-specific kernel, making it compatible with KubeVirt's virt machine type.

- **Kernel:** Using `linux-image-arm64` (generic ARM64 kernel, e.g., 6.12.95+deb13-arm64)
- **SSH Server:** `openssh-server` installed for remote access
- **Console:** Configured for `ttyAMA0` serial console
- **GRUB:** Configured to boot generic kernel without ACPI parameters
- **Network:** Integration tests use `physical-net` Multus network
```

- [ ] **Step 2: Update troubleshooting section**

After line 53:

```markdown
#### VM Still Crashes with Kernel Panic

If your VM still crashes after applying this fix:

1. Check the VM's kernel logs using `kubectl logs <pod-name>`
2. Verify the containerdisk image tag is correct
3. Check that the kernel is `linux-image-6.12.95+deb13-arm64` (not the RPi kernel)
4. Ensure your KubeVirt cluster has arm64 nodes available
5. Try deploying with increased timeout in the VM manifest

#### SSH Connection Fails

If you cannot SSH into the VM:

1. Verify the cloud-init userData includes SSH keys or password
2. Check the VM's network configuration
3. Ensure the physical-net network is properly configured
4. Check firewall rules on the host
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update for generic kernel fix"
```
