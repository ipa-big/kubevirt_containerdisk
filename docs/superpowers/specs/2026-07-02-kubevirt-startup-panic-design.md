# KubeVirt Startup Panic Fix Design

## Goal

Adjust the existing Raspberry Pi OS containerdisk build flow so the published KubeVirt containerdisk boots cleanly to a login prompt instead of failing with `Kernel panic - not syncing: Attempted to kill the idle task!`.

## Scope

This design covers:

- Targeted fixes to the current fixed-image build flow
- Boot-critical guest conversion changes inside the existing chroot stage
- Artifact sanity checks before containerdisk packaging
- A lightweight validation step before publish

This design does not cover:

- Replacing the current build flow with a new architecture
- Supporting additional operating system images or platforms
- Building a full KubeVirt end-to-end acceptance environment into CI

## Constraints and Success Criteria

### Constraints

- Preserve the current build flow and apply only targeted boot fixes
- Keep the current fixed Raspberry Pi OS image target
- The output remains a KubeVirt containerdisk image
- Validation can be added, but it must stay lightweight

### Success criteria

- The build still produces the expected KubeVirt containerdisk artifact
- The boot-critical guest configuration is explicit and internally consistent
- The build fails before publish if boot-critical sanity checks or validation fail
- A KubeVirt VM using the published containerdisk reaches a normal login prompt without startup issues

## Architecture

The existing dedicated build path stays in place. The change is conceptual rather than architectural: the conversion stage is no longer treated as a generic image rewrite, but as a KubeVirt-specific boot preparation stage with explicit validation gates.

The flow remains:

1. Download the fixed Raspberry Pi OS image
2. Expand and mount the image
3. Convert the guest inside the chroot
4. Generate the qcow2 artifact
5. Package the qcow2 as a containerdisk
6. Publish the container image

The design adds two controlled layers around the existing conversion path:

1. A boot-correction layer inside the chroot that sets KubeVirt boot assumptions explicitly
2. A validation layer after conversion and before publish

## Components

### Existing build script

The current dedicated build script remains the orchestration entrypoint. Its responsibility expands from “build a containerdisk” to “build a containerdisk that is explicitly prepared for KubeVirt boot semantics.”

### Boot-correction stage

This is the most important change. The chroot conversion must explicitly define and keep consistent the boot-critical configuration needed by the KubeVirt target. The design focuses on the following areas:

- Kernel package selection
- Initramfs generation
- Virtio-related module availability
- GRUB EFI installation and generated config
- GRUB kernel command line
- Root-device and filesystem mounting configuration
- Console configuration suitable for boot debugging and login access

These settings should be treated as one coherent unit. The design assumes the current panic is more likely caused by an inconsistent or incomplete guest boot configuration than by containerdisk packaging itself.

### Artifact sanity-check stage

After the guest is converted and before packaging, the script should verify that the boot-critical artifact state matches the intended design. This stage should inspect the guest filesystem and fail if any required boot assumption is missing or contradictory.

At minimum, the sanity checks should confirm:

- Expected kernel and initramfs files exist
- GRUB configuration references the intended boot artifacts consistently
- `/etc/fstab` matches the intended root and EFI layout
- Required boot-relevant modules or module configuration are present
- The qcow2 source artifact is produced in the expected location and name

### Lightweight validation stage

A lightweight validation step should run before publish. It should be stronger than static file checks but smaller than a full KubeVirt acceptance environment. The purpose is to catch obvious regressions earlier than the eventual VM boot.

The exact implementation can vary, but it should remain cheap enough for CI and should gate publishing.

## Detailed Flow

### 1. Preserve the existing build structure

The fixed-image build path stays intact so the fix remains narrow. Download, expansion, mount, qcow2 generation, and containerdisk packaging continue to follow the current flow.

### 2. Harden boot-critical guest conversion

Inside the chroot, the script should explicitly configure the guest for the KubeVirt boot environment rather than relying on loosely assembled boot settings. The design requires the conversion stage to treat kernel, initramfs, GRUB, root mounting, and virtio support as a single boot contract.

The conversion should make these expectations explicit and deterministic:

- The selected kernel package is the intended one for the KubeVirt guest
- Initramfs includes the required modules for the virtual hardware path
- GRUB is installed and configured for the intended EFI boot flow
- Kernel arguments required for stable boot and usable console access are set intentionally
- Root and EFI mounts resolve in the intended way at boot

### 3. Add post-conversion sanity checks

Before packaging, the script should inspect the converted guest and fail if boot-critical files or configuration are missing or inconsistent. This turns a late runtime panic into an earlier, labeled build failure.

### 4. Add lightweight validation before publish

Publishing should depend on a lightweight validation path passing. This validation should focus on catching boot regressions cheaply, not on replacing the final acceptance test.

### 5. Keep the real acceptance bar

The final acceptance condition remains the real workload behavior: a KubeVirt VM using the published containerdisk reaches a login prompt without startup issues.

## Error Handling

- Fail immediately on any boot-correction stage error
- Fail if sanity checks detect missing or contradictory boot-critical configuration
- Fail if lightweight validation does not pass
- Do not allow publish to proceed after a failed boot-oriented validation gate

The design intentionally moves failure earlier. A build should stop at the point the boot contract becomes invalid instead of allowing the first signal to be a runtime kernel panic in KubeVirt.

## Testing and Validation Strategy

### Build-time validation

The build should verify:

- Boot-critical configuration is written as intended
- Expected boot artifacts exist
- Packaging still produces the expected containerdisk artifact

### Lightweight pre-publish validation

The build should run a cheap validation step before publish to catch clear regressions in the guest boot path.

### Acceptance validation

The true acceptance test remains operational:

- Publish the containerdisk image
- Use it in a KubeVirt VM
- Confirm the VM reaches a normal login prompt without startup issues

## Repository Changes Expected

- Modify the dedicated build script rather than replacing it
- Add or strengthen boot-critical validation logic
- Add a lightweight validation gate before publish
- Update any related workflow or documentation only where necessary to support the targeted boot-fix flow

## Recommended Implementation Direction

Implement the fix as a focused KubeVirt boot hardening pass on the current script. That is the shortest path to solving the startup panic while preserving the working parts of the current build and keeping new validation lightweight.
