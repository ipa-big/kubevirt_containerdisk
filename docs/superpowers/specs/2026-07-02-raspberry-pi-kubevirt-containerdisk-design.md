# Raspberry Pi OS to KubeVirt Containerdisk Design

## Goal

Add a new standalone build script that downloads one fixed Raspberry Pi OS image, converts it into a KubeVirt-bootable guest, packages it as a containerdisk image, and pushes that image to GHCR. The existing `build.sh` remains in the repository unchanged.

## Scope

This design covers:

- A new script alongside `build.sh`
- One fixed Raspberry Pi OS source image
- End-to-end guest conversion for KubeVirt use
- Containerdisk image build and push to GHCR
- Local Linux and GitHub Actions execution

This design does not cover:

- Refactoring the existing `build.sh`
- Supporting multiple Raspberry Pi OS variants
- Generalizing the flow into a reusable image factory

## Constraints and Success Criteria

### Constraints

- The new script must coexist with `build.sh`
- The source image target is fixed in the script
- The script must work on local Linux hosts and in GitHub Actions on Ubuntu
- The output must be suitable for use as a KubeVirt containerdisk

### Success criteria

- The script completes end to end without manual intervention
- It pushes a container image to GHCR
- The image contains the generated `disc.qcow2` at `/disk/disk.qcow2`
- A KubeVirt VM can reference the pushed image and boot the converted guest

## Architecture

The repository gains a dedicated script whose single responsibility is building a containerdisk from one fixed Raspberry Pi OS image. Unlike `build.sh`, this script is not parameterized for image selection. It embeds the Raspberry Pi OS download URL, image filename, and target platform so the path stays deterministic and easier to debug.

The script is organized into the following stages:

1. Prerequisite validation
2. Source image download and decompression
3. Raw disk expansion and partition remapping
4. Filesystem mount and chroot preparation
5. Guest conversion for KubeVirt bootability
6. Cleanup and unmount
7. QCOW2 conversion
8. Containerdisk image build and GHCR push

Each stage has a clear boundary and should emit a short status message before running so failures can be tied to a specific step.

## Components

### New standalone script

The new script is the orchestration entrypoint. It owns the full flow from source image download through GHCR push. It should use strict shell behavior (`set -euo pipefail`) and validate all prerequisites before modifying the image.

### Existing Dockerfile

The existing `Dockerfile` can continue to package `disc.qcow2` into a scratch-based image with `/disk/disk.qcow2` owned by UID/GID `107:107`, matching KubeVirt expectations. The design assumes this image layout remains the containerdisk packaging mechanism.

### GitHub Actions workflow

CI should invoke the new script directly. GHCR login stays in the workflow, and the script follows the same fixed-image path in both CI and local runs to avoid environment-specific logic drift.

## Detailed Flow

### 1. Prerequisite validation

Before downloading anything, the script checks for required host tools and required credentials for GHCR push. It must fail immediately if a dependency is missing rather than partially progressing.

Required categories include:

- Image manipulation tools such as `qemu-img`, `kpartx`, `parted`, `growpart`, `e2fsck`, and `resize2fs`
- Mount and chroot support
- Docker with build capability
- GHCR authentication inputs

### 2. Source image handling

The script downloads a single fixed Raspberry Pi OS `.img.xz` artifact, then decompresses it into a raw `.img`. No runtime selection of alternative base images is part of this design.

### 3. Disk preparation

The raw image is expanded, its partition map is refreshed, and the root filesystem is grown. The EFI flag is set on the boot partition so the resulting guest can boot through the converted UEFI layout.

### 4. Mount and chroot preparation

The script mounts the root and EFI partitions, bind-mounts the required host pseudo-filesystems, and places `qemu-aarch64-static` into the guest so package installation and bootloader configuration can run under emulation.

### 5. Guest conversion

Inside the chroot, the script converts the Raspberry Pi OS image into a KubeVirt-ready guest by:

- Installing the ARM64 kernel and GRUB EFI packages
- Ensuring the required virtio modules are present in initramfs
- Rebuilding initramfs
- Installing GRUB for ARM64 EFI in removable mode
- Configuring GRUB kernel arguments for serial-console-friendly boot
- Disabling Linux PARTUUID usage where needed
- Rewriting `/etc/fstab` to mount the root and EFI filesystems by UUID
- Replacing `/boot/firmware` with a symlink to the EFI mount

This conversion stage is the heart of the design. The new script must preserve this behavior because packaging alone is insufficient; the guest must also boot correctly inside KubeVirt.

### 6. Cleanup

The script must always unmount the chroot mounts and release device mappings, including on failure. Cleanup behavior should be centralized so every exit path uses the same teardown logic.

### 7. QCOW2 generation

After conversion, the raw `.img` is converted into `disc.qcow2`. This file is retained locally as a build artifact and becomes the input to the containerdisk image build.

### 8. Containerdisk build and push

The script builds a container image that embeds `disc.qcow2` at `/disk/disk.qcow2` and pushes that image to GHCR. The image name can be fixed or derived from the fixed Raspberry Pi OS version, but the design expects a stable, predictable published reference.

## Runtime Inputs

The script should avoid image-selection inputs, but it still needs operational inputs for publishing:

- GHCR username
- GHCR token
- Optional final image tag override if the default published tag needs to be changed

All other source-image configuration stays embedded in the script.

## Error Handling

- Use strict shell execution and fail on first unexpected error
- Validate required tools and credentials before touching the image
- Print short stage markers before each major operation
- Do not silently skip failed setup or conversion steps
- Use centralized cleanup to avoid leaked mounts and loop-device mappings

The design favors explicit failure over fallback behavior. If guest conversion, image build, or push fails, the script exits non-zero with the failure occurring at a clearly labeled stage.

## Testing and Validation Strategy

This work is best validated as a workflow rather than through unit tests.

### Primary validation

- Run the new script locally on Linux
- Run the new script in GitHub Actions on Ubuntu
- Confirm the push to GHCR succeeds
- Confirm the resulting image contains `/disk/disk.qcow2`

### Acceptance validation

Use the published image as a KubeVirt containerdisk for a VM and verify that the VM boots the converted Raspberry Pi OS guest successfully. That is the final acceptance bar for the design.

## Repository Changes Expected

- Add a new standalone build script beside `build.sh`
- Update GitHub Actions to call the new script for this fixed Raspberry Pi OS containerdisk path
- Keep `build.sh` intact for the existing workflow

## Recommended Implementation Direction

Implement the new script as a focused, fixed-target workflow instead of refactoring `build.sh` first. This is the shortest path to a working result and keeps risk isolated to the new build path. If the new flow later proves stable and useful, shared helpers can be extracted afterward as a separate improvement.
