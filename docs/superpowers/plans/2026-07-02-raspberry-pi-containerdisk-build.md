# Raspberry Pi Containerdisk Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new standalone script that builds, converts, packages, and pushes a fixed Raspberry Pi OS image as a GHCR-hosted KubeVirt containerdisk while keeping `build.sh` untouched.

**Architecture:** Keep the existing repository layout, reuse the root `Dockerfile` for packaging, and add one new root-level shell entrypoint dedicated to the fixed Raspberry Pi OS image. Make the new script sourceable for testability, validate prerequisites up front, separate orchestration into named stage functions, and update CI and README to use the new path.

**Tech Stack:** Bash, Docker Buildx, GitHub Actions, GHCR, qemu-img, kpartx, growpart, GRUB EFI, KubeVirt containerdisk image layout

## Global Constraints

- The new script must coexist with `build.sh`
- The source image target is fixed in the script
- The script must work on local Linux hosts and in GitHub Actions on Ubuntu
- The output must be suitable for use as a KubeVirt containerdisk
- The script completes end to end without manual intervention
- It pushes a container image to GHCR
- The image contains the generated `disc.qcow2` at `/disk/disk.qcow2`
- A KubeVirt VM can reference the pushed image and boot the converted guest

---

## File Structure

- Create: `build-raspios-lite-containerdisk.sh` — dedicated entrypoint for the fixed Raspberry Pi OS image; owns validation, cleanup, guest conversion, qcow2 generation, and GHCR push.
- Create: `tests/build-raspios-lite-containerdisk.test.sh` — bash-based regression test script that sources the new builder and verifies constants, helper behavior, and orchestration order without running destructive host operations.
- Modify: `.github/workflows/main.yml` — replace the `build.sh` invocation with the new script and remove no-longer-needed image-selection environment variables from the workflow step.
- Modify: `README.md` — document the new script, the required credentials, the fixed source image behavior, and the produced GHCR/KubeVirt artifact.
- Reuse unchanged: `Dockerfile` — keep packaging `disc.qcow2` into `/disk/disk.qcow2` with UID/GID `107:107`.

### Task 1: Create the dedicated script contract and regression harness

**Files:**
- Create: `build-raspios-lite-containerdisk.sh`
- Create: `tests/build-raspios-lite-containerdisk.test.sh`

**Interfaces:**
- Consumes: existing repository root `Dockerfile`
- Produces:
  - `build-raspios-lite-containerdisk.sh` executable entrypoint
  - `default_image_tag() -> stdout string`
  - fixed readonly constants `IMG_URL`, `IMG_NAME`, `IMG_PLATFORM`
  - `main() -> exit status`

- [ ] **Step 1: Write the failing test**

Create `tests/build-raspios-lite-containerdisk.test.sh` with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/build-raspios-lite-containerdisk.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

test_script_exists() {
  [[ -f "${SCRIPT_PATH}" ]] || fail "missing ${SCRIPT_PATH}"
}

test_fixed_image_constants() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  assert_eq "${IMG_URL}" "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
  assert_eq "${IMG_NAME}" "2026-06-18-raspios-trixie-arm64-lite"
  assert_eq "${IMG_PLATFORM}" "linux/arm64"
}

test_script_is_sourceable() {
  local output_file
  output_file="$(mktemp)"
  bash -c "source '${SCRIPT_PATH}'" >"${output_file}" 2>&1
  [[ ! -s "${output_file}" ]] || fail "sourcing the script should not execute main"
  rm -f "${output_file}"
}

test_default_image_tag() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  assert_eq "$(default_image_tag)" "ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
}

test_script_exists
test_fixed_image_constants
test_script_is_sourceable
test_default_image_tag

echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL with `missing /home/.../build-raspios-lite-containerdisk.sh`

- [ ] **Step 3: Write minimal implementation**

Create `build-raspios-lite-containerdisk.sh` with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
readonly IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
readonly IMG_PLATFORM="linux/arm64"

default_image_tag() {
  printf 'ghcr.io/ipa-big/kubevirt_containerdisk/%s_uefi\n' "${IMG_NAME}"
}

main() {
  echo "not implemented yet" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Then mark it executable:

```bash
chmod +x build-raspios-lite-containerdisk.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "test: add fixed Raspberry Pi containerdisk script contract"
```

### Task 2: Add validation, stage logging, and cleanup behavior

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh:1-40`
- Modify: `tests/build-raspios-lite-containerdisk.test.sh:1-44`

**Interfaces:**
- Consumes:
  - `default_image_tag() -> stdout string`
  - fixed readonly constants `IMG_URL`, `IMG_NAME`, `IMG_PLATFORM`
- Produces:
  - `log_step(message) -> stdout formatted status line`
  - `require_env(var_name) -> exit 0/1`
  - `require_command(cmd_name) -> exit 0/1`
  - `validate_runtime_inputs() -> exit 0/1`
  - `validate_host_tools() -> exit 0/1`
  - `cleanup() -> exit 0`
  - readonly mount state vars `ROOT_MOUNT_DIR`, `EFI_MOUNT_DIR`

- [ ] **Step 1: Write the failing test**

Replace `tests/build-raspios-lite-containerdisk.test.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/build-raspios-lite-containerdisk.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

test_fixed_image_constants() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  assert_eq "${IMG_URL}" "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
  assert_eq "${IMG_NAME}" "2026-06-18-raspios-trixie-arm64-lite"
  assert_eq "${IMG_PLATFORM}" "linux/arm64"
}

test_default_image_tag() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  assert_eq "$(default_image_tag)" "ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
}

test_validate_runtime_inputs_requires_credentials() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  unset GHCR_USERNAME GHCR_TOKEN || true

  local output
  if output="$(validate_runtime_inputs 2>&1)"; then
    fail "validate_runtime_inputs should fail when credentials are missing"
  fi

  [[ "${output}" == *"GHCR_USERNAME"* ]] || fail "missing GHCR_USERNAME error"
}

test_log_step_prefix() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  local output
  output="$(log_step "Downloading image")"
  [[ "${output}" == *"==> Downloading image"* ]] || fail "missing log prefix"
}

test_cleanup_is_safe_when_nothing_is_mounted() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"
  cleanup
}

test_fixed_image_constants
test_default_image_tag
test_validate_runtime_inputs_requires_credentials
test_log_step_prefix
test_cleanup_is_safe_when_nothing_is_mounted

echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL with `validate_runtime_inputs: command not found`

- [ ] **Step 3: Write minimal implementation**

Replace `build-raspios-lite-containerdisk.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
readonly IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
readonly IMG_PLATFORM="linux/arm64"
readonly ROOT_MOUNT_DIR="/mnt/rpi_root"
readonly EFI_MOUNT_DIR="${ROOT_MOUNT_DIR}/boot/efi"

IMAGE_ARCHIVE=""
IMAGE_FILE=""
LOOP_DEVICE=""

log_step() {
  printf '==> %s\n' "$1"
}

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: required environment variable '${var_name}' is not set." >&2
    return 1
  fi
}

require_command() {
  local cmd_name="$1"
  if ! command -v "${cmd_name}" >/dev/null 2>&1; then
    echo "Error: required command '${cmd_name}' is not available." >&2
    return 1
  fi
}

validate_runtime_inputs() {
  require_env "GHCR_USERNAME"
  require_env "GHCR_TOKEN"
}

validate_host_tools() {
  local cmd
  for cmd in bash docker qemu-img sudo wget xz; do
    require_command "${cmd}"
  done
}

default_image_tag() {
  printf 'ghcr.io/ipa-big/kubevirt_containerdisk/%s_uefi\n' "${IMG_NAME}"
}

cleanup() {
  if mountpoint -q "${EFI_MOUNT_DIR}" 2>/dev/null; then
    sudo umount "${EFI_MOUNT_DIR}"
  fi

  if mountpoint -q "${ROOT_MOUNT_DIR}" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT_DIR}/dev" || true
    sudo umount "${ROOT_MOUNT_DIR}/proc" || true
    sudo umount "${ROOT_MOUNT_DIR}/sys" || true
    sudo umount "${ROOT_MOUNT_DIR}/run" || true
    sudo umount "${ROOT_MOUNT_DIR}"
  fi

  if [[ -n "${IMAGE_FILE}" ]]; then
    sudo kpartx -dv "${IMAGE_FILE}" >/dev/null 2>&1 || true
  fi
}

main() {
  validate_runtime_inputs
  validate_host_tools
  echo "not implemented yet" >&2
  return 1
}

trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && bash -n build-raspios-lite-containerdisk.sh`

Expected: `PASS` from the test script and no output from `bash -n`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "feat: add validation and cleanup for dedicated builder"
```

### Task 3: Implement the build, conversion, and publish orchestration

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh:1-120`
- Modify: `tests/build-raspios-lite-containerdisk.test.sh:1-55`

**Interfaces:**
- Consumes:
  - `log_step(message) -> stdout formatted status line`
  - `validate_runtime_inputs() -> exit 0/1`
  - `validate_host_tools() -> exit 0/1`
  - `default_image_tag() -> stdout string`
- Produces:
  - `install_host_dependencies() -> exit 0`
  - `download_source_image() -> exit 0`
  - `expand_and_map_image() -> exit 0`
  - `mount_guest_filesystems() -> exit 0`
  - `convert_guest_image() -> exit 0`
  - `unmount_guest_filesystems() -> exit 0`
  - `convert_to_qcow2() -> exit 0`
  - `build_containerdisk_image(image_tag) -> exit 0`
  - `main() -> exit 0`

- [ ] **Step 1: Write the failing test**

Replace `tests/build-raspios-lite-containerdisk.test.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/build-raspios-lite-containerdisk.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}', got '${actual}'"
}

test_main_runs_all_stages_in_order() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"

  local calls=()
  validate_runtime_inputs() { calls+=("validate_runtime_inputs"); }
  validate_host_tools() { calls+=("validate_host_tools"); }
  install_host_dependencies() { calls+=("install_host_dependencies"); }
  download_source_image() { calls+=("download_source_image"); }
  expand_and_map_image() { calls+=("expand_and_map_image"); }
  mount_guest_filesystems() { calls+=("mount_guest_filesystems"); }
  convert_guest_image() { calls+=("convert_guest_image"); }
  unmount_guest_filesystems() { calls+=("unmount_guest_filesystems"); }
  convert_to_qcow2() { calls+=("convert_to_qcow2"); }
  build_containerdisk_image() { calls+=("build_containerdisk_image:$1"); }
  log_step() { :; }

  main

  assert_eq "${calls[*]}" "validate_runtime_inputs validate_host_tools install_host_dependencies download_source_image expand_and_map_image mount_guest_filesystems convert_guest_image unmount_guest_filesystems convert_to_qcow2 build_containerdisk_image:ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
}

test_main_prefers_image_tag_override() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  export IMAGE_TAG_OVERRIDE="ghcr.io/example/custom:latest"

  local selected_tag=""
  validate_runtime_inputs() { :; }
  validate_host_tools() { :; }
  install_host_dependencies() { :; }
  download_source_image() { :; }
  expand_and_map_image() { :; }
  mount_guest_filesystems() { :; }
  convert_guest_image() { :; }
  unmount_guest_filesystems() { :; }
  convert_to_qcow2() { :; }
  build_containerdisk_image() { selected_tag="$1"; }
  log_step() { :; }

  main

  assert_eq "${selected_tag}" "ghcr.io/example/custom:latest"
}

test_main_runs_all_stages_in_order
test_main_prefers_image_tag_override

echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL with `install_host_dependencies: command not found`

- [ ] **Step 3: Write minimal implementation**

Replace `build-raspios-lite-containerdisk.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
readonly IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
readonly IMG_PLATFORM="linux/arm64"
readonly ROOT_MOUNT_DIR="/mnt/rpi_root"
readonly EFI_MOUNT_DIR="${ROOT_MOUNT_DIR}/boot/efi"

IMAGE_ARCHIVE=""
IMAGE_FILE=""
LOOP_DEVICE="/dev/loop0"

log_step() {
  printf '==> %s\n' "$1"
}

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: required environment variable '${var_name}' is not set." >&2
    return 1
  fi
}

require_command() {
  local cmd_name="$1"
  if ! command -v "${cmd_name}" >/dev/null 2>&1; then
    echo "Error: required command '${cmd_name}' is not available." >&2
    return 1
  fi
}

validate_runtime_inputs() {
  require_env "GHCR_USERNAME"
  require_env "GHCR_TOKEN"
}

validate_host_tools() {
  local cmd
  for cmd in bash blkid chroot docker e2fsck growpart kpartx mount mountpoint parted qemu-img resize2fs sudo umount wget xz; do
    require_command "${cmd}"
  done
}

default_image_tag() {
  printf 'ghcr.io/ipa-big/kubevirt_containerdisk/%s_uefi\n' "${IMG_NAME}"
}

cleanup() {
  if mountpoint -q "${ROOT_MOUNT_DIR}/dev" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/dev"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/proc" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/proc"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/sys" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/sys"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/run" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/run"; fi
  if mountpoint -q "${EFI_MOUNT_DIR}" 2>/dev/null; then sudo umount "${EFI_MOUNT_DIR}"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}"; fi
  if [[ -n "${IMAGE_FILE}" ]]; then sudo kpartx -dv "${IMAGE_FILE}" >/dev/null 2>&1 || true; fi
}

install_host_dependencies() {
  log_step "Installing host dependencies"
  sudo apt-get update -qq
  sudo apt-get install -qq -y cloud-guest-utils dosfstools e2fsprogs kpartx parted qemu-user-static qemu-utils wget xz-utils
}

download_source_image() {
  log_step "Downloading fixed Raspberry Pi OS image"
  IMAGE_ARCHIVE="${IMG_NAME}.img.xz"
  IMAGE_FILE="${IMG_NAME}.img"
  rm -f "${IMAGE_ARCHIVE}" "${IMAGE_FILE}" disc.qcow2
  wget -q -O "${IMAGE_ARCHIVE}" "${IMG_URL}"
  xz -d "${IMAGE_ARCHIVE}"
}

expand_and_map_image() {
  log_step "Expanding and mapping the image"
  qemu-img resize "${IMAGE_FILE}" +2G
  sudo kpartx -av "${IMAGE_FILE}"
  sudo growpart "${LOOP_DEVICE}" 2
  sudo kpartx -u "${IMAGE_FILE}"
  sudo parted "${LOOP_DEVICE}" set 1 esp on
  sudo e2fsck -fp /dev/mapper/loop0p2 || sudo e2fsck -fy /dev/mapper/loop0p2
  sudo resize2fs /dev/mapper/loop0p2
}

mount_guest_filesystems() {
  log_step "Mounting guest filesystems"
  sudo mkdir -p "${ROOT_MOUNT_DIR}" "${EFI_MOUNT_DIR}"
  sudo mount /dev/mapper/loop0p2 "${ROOT_MOUNT_DIR}"
  sudo mount /dev/mapper/loop0p1 "${EFI_MOUNT_DIR}"
  sudo cp /usr/bin/qemu-aarch64-static "${ROOT_MOUNT_DIR}/usr/bin/"
  sudo mount --bind /dev "${ROOT_MOUNT_DIR}/dev"
  sudo mount --bind /proc "${ROOT_MOUNT_DIR}/proc"
  sudo mount --bind /sys "${ROOT_MOUNT_DIR}/sys"
  sudo mount --bind /run "${ROOT_MOUNT_DIR}/run"
}

convert_guest_image() {
  log_step "Converting the guest for KubeVirt boot"
  sudo chroot "${ROOT_MOUNT_DIR}" /bin/bash -eux <<'EOF'
apt-get update -qq
apt-get install -qq -y linux-image-arm64 grub-efi-arm64

grep -qxF 'virtio' /etc/initramfs-tools/modules || echo 'virtio' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_blk' /etc/initramfs-tools/modules || echo 'virtio_blk' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_pci' /etc/initramfs-tools/modules || echo 'virtio_pci' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_net' /etc/initramfs-tools/modules || echo 'virtio_net' >> /etc/initramfs-tools/modules
update-initramfs -u -k all

grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
update-grub

sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyAMA0,115200 earlycon=pl011,0x09000000 rootwait"/' /etc/default/grub

if grep -q '^GRUB_DISABLE_LINUX_PARTUUID=' /etc/default/grub; then
  sed -i 's/^GRUB_DISABLE_LINUX_PARTUUID=.*/GRUB_DISABLE_LINUX_PARTUUID=true/' /etc/default/grub
else
  echo 'GRUB_DISABLE_LINUX_PARTUUID=true' >> /etc/default/grub
fi

sed -i '/^GRUB_TERMINAL_INPUT=/d;/^GRUB_TERMINAL_OUTPUT=/d;/^GRUB_SERIAL_COMMAND=/d' /etc/default/grub

if grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
  sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=console/' /etc/default/grub
else
  echo 'GRUB_TERMINAL=console' >> /etc/default/grub
fi

update-grub

BOOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p1)
ROOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p2)

cat <<FSTAB > /etc/fstab
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$BOOT_UUID /boot/efi vfat defaults 0 2
FSTAB

rm -rf /boot/firmware
ln -s efi /boot/firmware

update-grub
EOF
}

unmount_guest_filesystems() {
  log_step "Unmounting guest filesystems"
  sudo umount "${ROOT_MOUNT_DIR}/dev"
  sudo umount "${ROOT_MOUNT_DIR}/proc"
  sudo umount "${ROOT_MOUNT_DIR}/sys"
  sudo umount "${ROOT_MOUNT_DIR}/run"
  sudo umount "${EFI_MOUNT_DIR}"
  sudo umount "${ROOT_MOUNT_DIR}"
}

convert_to_qcow2() {
  log_step "Converting raw image to qcow2"
  qemu-img convert -f raw -O qcow2 "${IMAGE_FILE}" disc.qcow2
}

build_containerdisk_image() {
  local image_tag="$1"
  log_step "Building and pushing containerdisk image"
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
  docker buildx build --platform "${IMG_PLATFORM}" -t "${image_tag}" --push .
}

main() {
  local image_tag="${IMAGE_TAG_OVERRIDE:-$(default_image_tag)}"

  validate_runtime_inputs
  validate_host_tools
  install_host_dependencies
  download_source_image
  expand_and_map_image
  mount_guest_filesystems
  convert_guest_image
  unmount_guest_filesystems
  convert_to_qcow2
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}

trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && bash -n build-raspios-lite-containerdisk.sh`

Expected: `PASS` from the test script and no output from `bash -n`

- [ ] **Step 5: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "feat: implement dedicated Raspberry Pi containerdisk builder"
```

### Task 4: Wire CI and document the new build path

**Files:**
- Modify: `.github/workflows/main.yml:20-36`
- Modify: `README.md:1-10`

**Interfaces:**
- Consumes:
  - executable `build-raspios-lite-containerdisk.sh`
  - environment variables `GHCR_USERNAME`, `GHCR_TOKEN`
  - optional environment variable `IMAGE_TAG_OVERRIDE`
- Produces:
  - GitHub Actions workflow that invokes the new script directly
  - README usage instructions for local runs and the fixed-image behavior

- [ ] **Step 1: Write the failing test**

Add these assertions to the bottom of `tests/build-raspios-lite-containerdisk.test.sh`:

```bash
test_workflow_uses_new_script() {
  grep -Fq 'run: bash ./build-raspios-lite-containerdisk.sh' "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow is not using the new script"
}

test_readme_documents_new_script() {
  grep -Fq 'build-raspios-lite-containerdisk.sh' "${ROOT_DIR}/README.md" \
    || fail "README does not document the new script"
}

test_workflow_uses_new_script
test_readme_documents_new_script
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`

Expected: FAIL with `workflow is not using the new script`

- [ ] **Step 3: Write minimal implementation**

Update `.github/workflows/main.yml` so the build step becomes:

```yaml
      - name: Run dedicated Raspberry Pi containerdisk build
        env:
          GHCR_USERNAME: ${{ github.actor }}
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash ./build-raspios-lite-containerdisk.sh
```

Remove the no-longer-used `PUSH_IMAGE`, `IMG_URL`, `IMG_NAME`, and `IMG_PLATFORM` environment entries from that workflow step.

Replace `README.md` with:

````markdown
## Raspberry Pi OS containerdisk build

Use `build-raspios-lite-containerdisk.sh` to build a KubeVirt-ready containerdisk from the fixed Raspberry Pi OS image `2026-06-18-raspios-trixie-arm64-lite.img.xz`.

### Required environment variables

- `GHCR_USERNAME`
- `GHCR_TOKEN`
- `IMAGE_TAG_OVERRIDE` (optional)

### Local usage

```bash
export GHCR_USERNAME=your-github-user
export GHCR_TOKEN=your-ghcr-token
bash ./build-raspios-lite-containerdisk.sh
```

The script publishes a GHCR image containing `disc.qcow2` at `/disk/disk.qcow2`, ready to use as a KubeVirt containerdisk.

## References

| Titel                                                               | URL                                                                                  |
|---------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| UEFI auf dem Raspberry Pi                                           | https://www.linux-community.de/ausgaben/linuxuser/2025/10/uefi-auf-dem-raspberry-pi/ |
| Raspberry Pi Firmware                                               | https://github.com/raspberrypi/firmware                                              |
| Raspberry Pi 4 UEFI Firmware Images                                 | https://github.com/pftf/RPi4                                                         |
| firmware development environment for the UEFI and PI specifications | https://github.com/tianocore/edk2                                                    |
| Raspberry Pi 4 UEFI won't boot                                      | https://github.com/pftf/RPi4/issues/178                                              |
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh && rg -n "build-raspios-lite-containerdisk.sh|GHCR_USERNAME|GHCR_TOKEN" README.md .github/workflows/main.yml`

Expected:
- `PASS` from the test script
- one match in `.github/workflows/main.yml` showing `run: bash ./build-raspios-lite-containerdisk.sh`
- README matches for `build-raspios-lite-containerdisk.sh`, `GHCR_USERNAME`, and `GHCR_TOKEN`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/main.yml README.md tests/build-raspios-lite-containerdisk.test.sh
git commit -m "docs: wire CI and usage for dedicated Raspberry Pi builder"
```
