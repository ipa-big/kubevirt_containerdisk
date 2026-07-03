# VM Kernel Panic Fix Design

> **Design Date:** 2026-07-03  
> **Issue:** VM based on Raspberry Pi OS containerdisk crashes with kernel panic during boot in KubeVirt ARM64

## 1. Problem Statement

A VM based on the Raspberry Pi OS containerdisk crashes with a kernel panic during boot in KubeVirt on ARM64 nodes. The panic occurs in `nr_free_zone_pages+0x40/0xd8` during early memory management initialization.

### Root Cause

KubeVirt's QEMU configuration for ARM64 VMs:
- Uses `virt-rhel9.8.0` machine type with **ACPI enabled** (`acpi=on`)
- GIC version 2 for interrupt handling
- Host CPU passthrough (`-cpu host`)
- UEFI firmware (`/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw`)

The Raspberry Pi OS kernel expects device tree-based boot but receives ACPI tables instead, causing memory zone initialization to fail.

---

## 2. Solution Overview

**Approach:** Modify the containerdisk to force ACPI usage via kernel command line parameters.

**High-level strategy:**
1. Update `/boot/cmdline.txt` to include `acpi=force` and fix console settings
2. Update `/boot/config.txt` to disable graphics overlay that may conflict
3. Add fallback mechanism for if full ACPI fails

---

## 3. Architecture

### 3.1 Components

| Component | Purpose |
|-----------|---------|
| Modified `/boot/cmdline.txt` | Add `acpi=force` and proper console settings |
| Modified `/boot/config.txt` | Disable graphics overlay that conflicts with VM |
| Fallback cmdline file | `acpi=ht` (hardware tables only) if full ACPI fails |

### 3.2 Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ KubeVirt VM starts with UEFI firmware                          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ UEFI reads /boot/cmdline.txt from first FAT partition          │
│ Contains: acpi=force console=ttyAMA0... root=PARTUUID=...      │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kernel loads with ACPI forced by command line                  │
│ Attempts to use ACPI tables from UEFI                          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Kernel should initialize memory zones correctly                │
│ Should reach login prompt (or fail with clearer error)         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Configuration Changes

### 4.1 `/boot/cmdline.txt`

**Current:**
```
console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize---
```

**Proposed:**
```
console=ttyAMA0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait acpi=force no_timer_check
```

**Changes:**
- `console=ttyAMA0,115200` - Use serial console available in KubeVirt
- `acpi=force` - Force ACPI usage (primary fix)
- `no_timer_check` - Skip timer calibration that may fail in VM
- Removed `resize` - May not work reliably in VM context

### 4.2 `/boot/config.txt`

**Changes:**
```diff
- dtoverlay=vc4-kms-v3d
+ # dtoverlay=vc4-kms-v3d  # Disabled for KubeVirt compatibility
```

**Rationale:** The VC4 KMS V3D graphics overlay may conflict with KubeVirt's virtual GPU or cause issues in headless VM environment.

### 4.3 Fallback cmdline file

**File:** `/boot/cmdline_acpi_fallback.txt`

```
console=ttyAMA0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait acpi=ht no_timer_check
```

**Purpose:** If `acpi=force` fails, this provides `acpi=ht` (hardware tables only) as fallback.

---

## 5. Build Script Changes

### 5.1 `build-raspios-lite-containerdisk.sh` modifications

**Location:** After mounting `/boot/efi` partition, before conversion to qcow2

**Additions:**

```bash
# Fix console and add ACPI force to cmdline
BOOT_MOUNT_DIR="/mnt/rpi_root/boot/efi"
if [[ -f "${BOOT_MOUNT_DIR}/cmdline.txt" ]]; then
  # Backup original
  sudo cp "${BOOT_MOUNT_DIR}/cmdline.txt" "${BOOT_MOUNT_DIR}/cmdline_orig.txt" 2>/dev/null || true
  
  # Update cmdline with ACPI force and proper console
  sudo sed -i 's/console=serial0,115200/console=ttyAMA0,115200/' "${BOOT_MOUNT_DIR}/cmdline.txt"
  sudo sed -i 's/rootwait rootwait/rootwait acpi=force no_timer_check/' "${BOOT_MOUNT_DIR}/cmdline.txt"
  
  # Create fallback cmdline
  sudo sed 's/acpi=force/acpi=ht/' "${BOOT_MOUNT_DIR}/cmdline.txt" | \
    sudo tee "${BOOT_MOUNT_DIR}/cmdline_acpi_fallback.txt" >/dev/null
fi

# Disable VC4 graphics overlay for KubeVirt compatibility
if [[ -f "${BOOT_MOUNT_DIR}/config.txt" ]]; then
  sudo sed -i 's/^dtoverlay=vc4-kms-v3d$/# dtoverlay=vc4-kms-v3d  # Disabled for KubeVirt/' "${BOOT_MOUNT_DIR}/config.txt"
fi
```

---

## 6. Error Handling

### 6.1 If `acpi=force` fails

- Kernel will panic with clearer error message about ACPI
- Use fallback cmdline with `acpi=ht` (hardware tables only)

### 6.2 If both approaches fail

- Kernel panic will show specific error (e.g., "ACPI table parsing failed")
- This provides actionable feedback for further debugging

### 6.3 Recovery

- Containerdisk remains compatible with bare-metal Raspberry Pi
- Fallback cmdline allows testing alternative approaches
- Original cmdline preserved in `cmdline_orig.txt`

---

## 7. Testing

### 7.1 Local QEMU test

```bash
# Test with same machine type as KubeVirt
qemu-system-aarch64 \
  -M virt-rhel9.8.0 \
  -cpu host \
  -m 1024 \
  -nographic \
  -serial mon:stdio \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/tmp/aavmf_vars.fd \
  -drive file=disc.qcow2,if=virtio,format=qcow2
```

**Expected:** Kernel reaches login prompt without panic

### 7.2 KubeVirt test

1. Deploy modified containerdisk to KubeVirt cluster
2. Create VM with same manifest as before
3. Monitor VM logs for successful boot

**Success criteria:**
- VM reaches login prompt
- Serial console is accessible
- No kernel panic messages

### 7.3 Backward compatibility

- Containerdisk should still boot on bare-metal Raspberry Pi
- Fallback mechanism provides safety net
- Original cmdline preserved for recovery

---

## 8. Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| `acpi=force` causes different panic | Medium | Fallback `acpi=ht` available |
| Graphics overlay removal breaks local use | Low | Overlay can be re-enabled manually |
| Console change breaks some setups | Low | Original cmdline preserved in backup |
| KubeVirt-specific machine type not recognized | Low | Falls back to generic behavior |

---

## 9. Next Steps

1. Implement changes to `build-raspios-lite-containerdisk.sh`
2. Test locally with QEMU using KubeVirt's machine type
3. Deploy to KubeVirt and verify VM boots successfully
4. Monitor for any side effects or errors

---

## Appendix A: Kernel Panic Details

```
Unable to handle kernel paging request at virtual address 0000000000001b08
[0000000000001b08] user address but active_mm is swapper
Internal error: Oops: 0000000096000005 [#1] SMP
CPU: 0 UID: 0 PID: 0 Comm: swapper
pc : nr_free_zone_pages+0x40/0xd8
lr : build_all_zonelists+0x2c/0xb0
```

---

## Appendix B: KubeVirt QEMU Configuration

From VM logs:
```
-machine virt-rhel9.8.0,usb=off,gic-version=2,dump-guest-core=off,memory-backend=mach-virt.ram,pflash0=libvirt-pflash0-format,pflash1=libvirt-pflash1-storage,acpi=on
-accel kvm
-cpu host
-m size=1048576k
```