# VM Kernel Panic Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Raspberry Pi-specific kernel with a generic ARM64 kernel that works with KubeVirt's virt machine

**Architecture:** The build script will install `linux-image-arm64`, remove the RPi kernel packages, configure GRUB to boot the generic kernel, and generate a fresh initramfs

**Tech Stack:** Bash, Debian packages, GRUB, initramfs-tools, KubeVirt

## Global Constraints

- Build script: `build-raspios-lite-containerdisk.sh`
- Target kernel: `linux-image-6.12.94+deb13-arm64` (from `linux-image-arm64` package)
- Container disk image: `ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi`
- KubeVirt nodes: 3 arm64 (k3s-node-4, 5, 6) and 3 amd64
- Kernel must support virtio devices for containerDisk
- No kernel panic on VM boot

---
### Task 1: Remove Raspberry Pi kernel packages

**Files:**
- Create: `/home/operation/kubevirt_containerdisk/docs/superpowers/plans/2026-07-05-kernel-fix.md`
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:212-230`

**Interfaces:**
- Consumes: Current chroot environment with RPi kernel installed
- Produces: Clean chroot with only generic ARM64 kernel

- [ ] **Step 1: Add kernel removal commands after apt-get install**

After line 213 (after `apt-get install -qq -y linux-image-arm64 grub-efi-arm64`), add:

```bash
# Remove Raspberry Pi kernel packages
apt-get remove -y --purge linux-image-6.18.34+rpt-rpi-v8 linux-image-rpi-v8
apt-get autoremove -y --purge
```

- [ ] **Step 2: Update initramfs for specific kernel**

Replace line 219 (`update-initramfs -u -k all`) with:

```bash
# Generate initramfs for the generic ARM64 kernel only
update-initramfs -c -k 6.12.94+deb13-arm64
```

- [ ] **Step 3: Run test to verify kernels removed**

Build with `PUSH_IMAGE=false` and check chroot:

```bash
bash -c 'source build-raspios-lite-containerdisk.sh'
# After convert_guest_image, verify:
ls /tmp/mountpoint/lib/modules/
# Should show only 6.12.94+deb13-arm64
```

Expected: Only `6.12.94+deb13-arm64` in modules directory

- [ ] **Step 4: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: remove RPi kernel, use generic ARM64 kernel"
```

---

### Task 2: Update GRUB configuration for generic kernel

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:228-250`

**Interfaces:**
- Consumes: GRUB configuration files in chroot
- Produces: GRUB configured to boot generic kernel with correct cmdline

- [ ] **Step 1: Update GRUB_CMDLINE_LINUX_DEFAULT**

Replace line 228:

```bash
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyAMA0,115200 earlycon=pl011,0x09000000 rootwait"/' /etc/default/grub
```

Remove `acpi=force` and `no_timer_check` from cmdline

- [ ] **Step 2: Ensure GRUB_DEFAULT=0**

After line 228, add:

```bash
# Boot first menu entry (generic kernel)
if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
else
  echo 'GRUB_DEFAULT=0' >> /etc/default/grub
fi
```

- [ ] **Step 3: Verify cmdline.txt in boot partition**

The cmdline.txt should NOT contain `acpi=force` or `no_timer_check`. Verify by adding after line 248:

```bash
# Verify cmdline.txt doesn't have problematic parameters
grep -q "acpi=force" /boot/firmware/cmdline.txt && { echo "ERROR: acpi=force in cmdline.txt"; exit 1; }
grep -q "no_timer_check" /boot/firmware/cmdline.txt && { echo "ERROR: no_timer_check in cmdline.txt"; exit 1; }
```

- [ ] **Step 4: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "feat: configure GRUB for generic kernel boot"
```

---

### Task 3: Update verification checks

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh:260-270`

**Interfaces:**
- Consumes: Modified build script
- Produces: Verification that generic kernel is in use

- [ ] **Step 1: Update run_guest_boot_sanity_checks**

Update lines 266-268 to check the correct kernel version:

```bash
# Check generic kernel modules are present
sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_blk$' /etc/initramfs-tools/modules
sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_pci$' /etc/initramfs-tools/modules
sudo chroot "${ROOT_MOUNT_DIR}" grep -q '^virtio_net$' /etc/initramfs-tools/modules

# Verify only generic kernel is installed
sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep 'linux-image-6\.12\.94+deb13-arm64' | grep -q '^ii'
```

- [ ] **Step 2: Update sanity checks**

After line 268, add:

```bash
# Verify no RPi kernel packages
sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep -q 'linux-image-6\.18\.34+rpt-rpi-v8' && { echo "ERROR: RPi kernel still installed"; exit 1; }
sudo chroot "${ROOT_MOUNT_DIR}" dpkg -l | grep -q 'linux-image-rpi-v8' && { echo "ERROR: RPi meta-package still installed"; exit 1; }
```

- [ ] **Step 3: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "test: update sanity checks for generic kernel"
```

---

### Task 4: Test build end-to-end

**Files:**
- Test: `/home/operation/kubevirt_containerdisk/build-raspios-lite-containerdisk.sh`
- Test: `/home/operation/kubevirt_containerdisk/tests/vm-integration-test.sh`

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

- [ ] **Step 2: Test boot in KubeVirt**

```bash
kubectl delete vm raspios-vm -n default 2>/dev/null
bash tests/vm-integration-test.sh
```

Expected: VM boots, SSH accessible, no kernel panic

- [ ] **Step 3: Verify kernel version**

```bash
ssh -o StrictHostKeyChecking=no debian@<vm-ip> "uname -r"
```

Expected: Output `6.12.94+deb13-arm64`

- [ ] **Step 4: Push image to GHCR**

```bash
unset PUSH_IMAGE
bash ./build-raspios-lite-containerdisk.sh
```

Expected: Image pushed to `ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh
git commit -m "test: verify generic kernel works in KubeVirt"
```

---

### Task 5: Update documentation

**Files:**
- Modify: `/home/operation/kubevirt_containerdisk/README.md`

**Interfaces:**
- Consumes: Updated behavior
- Produces: Correct documentation

- [ ] **Step 1: Update README**

Replace lines 9-13 with:

```markdown
- **Console Configuration:** Changed from `serial0` to `ttyAMA0` for proper serial console output
- **Graphics Overlay:** Disabled `vc4-kms-v3d` overlay that conflicts with VM graphics
- **Kernel:** Using generic `linux-image-arm64` kernel compatible with KubeVirt virt machines
```

- [ ] **Step 2: Update troubleshooting section**

Add after line 53:

```markdown
#### VM Still Crashes with Kernel Panic

If your VM still crashes after applying this fix:

1. Check the VM's kernel logs using `kubectl logs <pod-name>`
2. Verify the containerdisk image tag is correct
3. Check that the kernel is `linux-image-6.12.94+deb13-arm64` (not the RPi kernel)
4. Ensure your KubeVirt cluster has arm64 nodes available
5. Try deploying with increased timeout in the VM manifest
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update for generic kernel fix"
```
