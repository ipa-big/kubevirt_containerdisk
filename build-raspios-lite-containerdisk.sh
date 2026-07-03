#!/usr/bin/env bash
set -euo pipefail

set_fixed_constant() {
  local name="$1"
  local value="$2"
  local declaration

  if declaration="$(declare -p "${name}" 2>/dev/null)"; then
    if [[ "${declaration}" == *"declare -r"* ]]; then
      if [[ "${!name}" != "${value}" ]]; then
        echo "Error: fixed constant '${name}' is readonly with unexpected value '${!name}'." >&2
        return 1
      fi
      return 0
    fi
    unset "${name}" || true
  fi

  printf -v "${name}" '%s' "${value}"
  readonly "${name}"
}

set_fixed_constant IMG_URL "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
set_fixed_constant IMG_NAME "2026-06-18-raspios-trixie-arm64-lite"
set_fixed_constant IMG_SHA256 "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
set_fixed_constant IMG_PLATFORM "linux/arm64"
set_fixed_constant ROOT_MOUNT_DIR "/mnt/rpi_root"
set_fixed_constant EFI_MOUNT_DIR "${ROOT_MOUNT_DIR}/boot/efi"
set_fixed_constant BOOT_SMOKE_TIMEOUT_SECONDS "180"
set_fixed_constant BOOT_SMOKE_UEFI_CODE_FD "/usr/share/AAVMF/AAVMF_CODE.fd"
set_fixed_constant BOOT_SMOKE_UEFI_VARS_TEMPLATE_FD "/usr/share/AAVMF/AAVMF_VARS.fd"
set_fixed_constant BOOT_SMOKE_UEFI_VARS_FD ".boot-smoke-aavmf-vars.fd"

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

require_file() {
  local file_path="$1"
  if [[ ! -f "${file_path}" ]]; then
    echo "Error: required file '${file_path}' is not available." >&2
    return 1
  fi
}

validate_runtime_inputs() {
  local push_image_status=0

  if should_push_image; then
    require_env "GHCR_USERNAME" || return 1
    require_env "GHCR_TOKEN" || return 1
  else
    push_image_status=$?
    if [[ "${push_image_status}" -ne 1 ]]; then
      return "${push_image_status}"
    fi
  fi
}

validate_bootstrap_tools() {
  local cmd
  for cmd in apt-get awk bash chroot cp docker mount mountpoint sudo umount; do
    require_command "${cmd}" || return 1
  done

  docker info >/dev/null 2>&1 || {
    echo "Error: Docker daemon is not accessible." >&2
    return 1
  }

  docker buildx version >/dev/null 2>&1 || {
    echo "Error: docker buildx is not available." >&2
    return 1
  }
}

validate_host_tools() {
  local cmd
  validate_bootstrap_tools || return 1
  for cmd in e2fsck growpart kpartx parted qemu-aarch64-static qemu-img qemu-system-aarch64 resize2fs sha256sum timeout wget xz; do
    require_command "${cmd}" || return 1
  done
  require_file "${BOOT_SMOKE_UEFI_CODE_FD}" || return 1
  require_file "${BOOT_SMOKE_UEFI_VARS_TEMPLATE_FD}" || return 1
}

default_image_tag() {
  printf 'ghcr.io/ipa-big/kubevirt_containerdisk/%s_uefi\n' "${IMG_NAME}"
}

should_push_image() {
  case "${PUSH_IMAGE:-true}" in
    1|true|TRUE|yes|YES) return 0 ;;
    0|false|FALSE|no|NO) return 1 ;;
    *)
      echo "Error: PUSH_IMAGE must be a boolean value." >&2
      return 2
      ;;
  esac
}

cleanup() {
  rm -f "${BOOT_SMOKE_UEFI_VARS_FD}" || true
  if mountpoint -q "${ROOT_MOUNT_DIR}/dev" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/dev" || true; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/proc" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/proc" || true; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/sys" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/sys" || true; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/run" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}/run" || true; fi
  if mountpoint -q "${EFI_MOUNT_DIR}" 2>/dev/null; then sudo umount "${EFI_MOUNT_DIR}" || true; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}" 2>/dev/null; then sudo umount "${ROOT_MOUNT_DIR}" || true; fi
  if [[ -n "${IMAGE_FILE}" ]]; then sudo kpartx -dv "${IMAGE_FILE}" >/dev/null 2>&1 || true; fi
}

install_host_dependencies() {
  log_step "Installing host dependencies"
  sudo apt-get update -qq
  sudo apt-get install -qq -y cloud-guest-utils dosfstools e2fsprogs kpartx parted qemu-efi-aarch64 qemu-system-arm qemu-user-static qemu-utils wget xz-utils
}

download_source_image() {
  log_step "Downloading fixed Raspberry Pi OS image"
  IMAGE_ARCHIVE="${IMG_NAME}.img.xz"
  IMAGE_FILE="${IMG_NAME}.img"
  rm -f "${IMAGE_ARCHIVE}" "${IMAGE_FILE}" disc.qcow2 disk.qcow2
  wget -q -O "${IMAGE_ARCHIVE}" "${IMG_URL}"
  sha256sum -c - <<< "${IMG_SHA256}  ${IMAGE_ARCHIVE}" || return 1
  xz -d "${IMAGE_ARCHIVE}"
}

expand_and_map_image() {
  log_step "Expanding and mapping the image"
  qemu-img resize "${IMAGE_FILE}" +2G

  local map_output
  map_output="$(sudo kpartx -av "${IMAGE_FILE}")"
  LOOP_DEVICE="/dev/$(printf '%s\n' "${map_output}" | awk '/^add map / {sub(/p[0-9]+$/, "", $3); print $3; exit}')"

  if [[ -z "${LOOP_DEVICE}" || "${LOOP_DEVICE}" == "/dev/" ]]; then
    echo "Error: could not determine loop device from kpartx output." >&2
    return 1
  fi

  if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm settle
  fi

  sudo growpart "${LOOP_DEVICE}" 2
  sudo kpartx -u "${IMAGE_FILE}"
  sudo parted -s "${LOOP_DEVICE}" set 1 esp on

  local root_partition
  root_partition="/dev/mapper/$(basename "${LOOP_DEVICE}")p2"
  sudo e2fsck -fp "${root_partition}" || sudo e2fsck -fy "${root_partition}"
  sudo resize2fs "${root_partition}"
}

mount_guest_filesystems() {
  log_step "Mounting guest filesystems"
  sudo mkdir -p "${ROOT_MOUNT_DIR}"
  sudo mount "/dev/mapper/$(basename "${LOOP_DEVICE}")p2" "${ROOT_MOUNT_DIR}"
  sudo mkdir -p "${EFI_MOUNT_DIR}"
  sudo mount "/dev/mapper/$(basename "${LOOP_DEVICE}")p1" "${EFI_MOUNT_DIR}"
  sudo cp /usr/bin/qemu-aarch64-static "${ROOT_MOUNT_DIR}/usr/bin/"
  sudo mount --bind /dev "${ROOT_MOUNT_DIR}/dev"
  sudo mount --bind /proc "${ROOT_MOUNT_DIR}/proc"
  sudo mount --bind /sys "${ROOT_MOUNT_DIR}/sys"
  sudo mount --bind /run "${ROOT_MOUNT_DIR}/run"
}

convert_guest_image() {
  log_step "Converting the guest for KubeVirt boot"
  local loop_basename root_partition boot_partition
  loop_basename="$(basename "${LOOP_DEVICE}")"
  root_partition="/dev/mapper/${loop_basename}p2"
  boot_partition="/dev/mapper/${loop_basename}p1"

  sudo chroot "${ROOT_MOUNT_DIR}" /bin/bash -eux <<EOF
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

BOOT_UUID=\$(blkid -o value -s UUID ${boot_partition})
ROOT_UUID=\$(blkid -o value -s UUID ${root_partition})

cat <<FSTAB > /etc/fstab
UUID=\$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=\$BOOT_UUID /boot/efi vfat defaults 0 2
FSTAB

rm -rf /boot/firmware
ln -s efi /boot/firmware

update-grub
EOF
}

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
}

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

run_boot_smoke_validation() {
  log_step "Running lightweight boot smoke validation"

  local boot_output=""
  local boot_status=0

  rm -f "${BOOT_SMOKE_UEFI_VARS_FD}"
  cp "${BOOT_SMOKE_UEFI_VARS_TEMPLATE_FD}" "${BOOT_SMOKE_UEFI_VARS_FD}"

  if boot_output="$(
    timeout "${BOOT_SMOKE_TIMEOUT_SECONDS}" \
      qemu-system-aarch64 \
        -M virt \
        -cpu cortex-a72 \
        -m 2048 \
        -nographic \
        -serial mon:stdio \
        -drive "if=pflash,format=raw,readonly=on,file=${BOOT_SMOKE_UEFI_CODE_FD}" \
        -drive "if=pflash,format=raw,file=${BOOT_SMOKE_UEFI_VARS_FD}" \
        -snapshot \
        -drive "file=disc.qcow2,if=virtio,format=qcow2"
  )"; then
    boot_status=0
  else
    boot_status=$?
  fi

  rm -f "${BOOT_SMOKE_UEFI_VARS_FD}"

  if [[ "${boot_output}" == *"login:"* ]]; then
    return 0
  fi

  printf '%s\n' "${boot_output}" >&2
  if [[ "${boot_status}" -eq 124 ]]; then
    echo "Error: boot smoke validation timed out before reaching a login prompt." >&2
  else
    echo "Error: boot smoke validation did not reach a login prompt." >&2
  fi
  return 1
}

unmount_guest_filesystems() {
  log_step "Unmounting guest filesystems"
  if mountpoint -q "${ROOT_MOUNT_DIR}/dev"; then sudo umount "${ROOT_MOUNT_DIR}/dev"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/proc"; then sudo umount "${ROOT_MOUNT_DIR}/proc"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/sys"; then sudo umount "${ROOT_MOUNT_DIR}/sys"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}/run"; then sudo umount "${ROOT_MOUNT_DIR}/run"; fi
  if mountpoint -q "${EFI_MOUNT_DIR}"; then sudo umount "${EFI_MOUNT_DIR}"; fi
  if mountpoint -q "${ROOT_MOUNT_DIR}"; then sudo umount "${ROOT_MOUNT_DIR}"; fi
}

convert_to_qcow2() {
  log_step "Converting raw image to qcow2"
  qemu-img convert -f raw -O qcow2 "${IMAGE_FILE}" disc.qcow2
}

build_containerdisk_image() {
  local image_tag="$1"
  local push_image_status=0

  if should_push_image; then
    log_step "Building and pushing containerdisk image"
    docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin <<< "${GHCR_TOKEN}"
    docker buildx build --platform "${IMG_PLATFORM}" -t "${image_tag}" --push .
  else
    push_image_status=$?
    if [[ "${push_image_status}" -ne 1 ]]; then
      return "${push_image_status}"
    fi
    log_step "Building containerdisk image without publishing"
    docker buildx build --platform "${IMG_PLATFORM}" -t "${image_tag}" --load .
  fi
}

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
  # run_boot_smoke_validation
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap cleanup EXIT
  main "$@"
fi
