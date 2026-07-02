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

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] || fail "expected '${haystack}' to contain '${needle}'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" != *"${needle}"* ]] || fail "expected '${haystack}' to not contain '${needle}'"
}

line_number_of() {
  local haystack="$1"
  local needle="$2"

  printf '%s\n' "${haystack}" | grep -Fn "${needle}" | head -n1 | cut -d: -f1
}

extract_job_block() {
  local job_name="$1"

  awk -v job_name="${job_name}" '
    $0 ~ "^  " job_name ":" { in_job=1 }
    in_job {
      if ($0 ~ "^  [A-Za-z0-9_-]+:" && $0 !~ "^  " job_name ":") {
        exit
      }
      print
    }
  ' "${ROOT_DIR}/.github/workflows/main.yml"
}

test_main_runs_all_stages_in_order() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

  local calls=()
  validate_runtime_inputs() { calls+=("validate_runtime_inputs"); }
  validate_bootstrap_tools() { calls+=("validate_bootstrap_tools"); }
  install_host_dependencies() { calls+=("install_host_dependencies"); }
  validate_host_tools() { calls+=("validate_host_tools"); }
  download_source_image() { calls+=("download_source_image"); }
  expand_and_map_image() { calls+=("expand_and_map_image"); }
  mount_guest_filesystems() { calls+=("mount_guest_filesystems"); }
  convert_guest_image() { calls+=("convert_guest_image"); }
  unmount_guest_filesystems() { calls+=("unmount_guest_filesystems"); }
  convert_to_qcow2() { calls+=("convert_to_qcow2"); }
  build_containerdisk_image() { calls+=("build_containerdisk_image:$1"); }
  log_step() { :; }

  main

  assert_eq "${calls[*]}" "validate_runtime_inputs validate_bootstrap_tools install_host_dependencies validate_host_tools download_source_image expand_and_map_image mount_guest_filesystems convert_guest_image unmount_guest_filesystems convert_to_qcow2 build_containerdisk_image:ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
}

test_main_stops_before_qcow2_when_unmount_fails() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

  local calls=()
  validate_runtime_inputs() { calls+=("validate_runtime_inputs"); }
  validate_bootstrap_tools() { calls+=("validate_bootstrap_tools"); }
  install_host_dependencies() { calls+=("install_host_dependencies"); }
  validate_host_tools() { calls+=("validate_host_tools"); }
  download_source_image() { calls+=("download_source_image"); }
  expand_and_map_image() { calls+=("expand_and_map_image"); }
  mount_guest_filesystems() { calls+=("mount_guest_filesystems"); }
  convert_guest_image() { calls+=("convert_guest_image"); }
  unmount_guest_filesystems() { calls+=("unmount_guest_filesystems"); return 1; }
  convert_to_qcow2() { calls+=("convert_to_qcow2"); }
  build_containerdisk_image() { calls+=("build_containerdisk_image:$1"); }
  log_step() { :; }

  if main; then
    fail "expected main to fail when unmount_guest_filesystems fails"
  fi

  assert_eq "${calls[*]}" "validate_runtime_inputs validate_bootstrap_tools install_host_dependencies validate_host_tools download_source_image expand_and_map_image mount_guest_filesystems convert_guest_image unmount_guest_filesystems"
}

test_main_prefers_image_tag_override() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  export IMAGE_TAG_OVERRIDE="ghcr.io/example/custom:latest"

  local selected_tag=""
  validate_runtime_inputs() { :; }
  validate_bootstrap_tools() { :; }
  install_host_dependencies() { :; }
  validate_host_tools() { :; }
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
  unset IMAGE_TAG_OVERRIDE
}

test_validate_runtime_inputs_skips_ghcr_credentials_when_push_disabled() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  unset GHCR_USERNAME GHCR_TOKEN
  export PUSH_IMAGE=false

  validate_runtime_inputs

  unset PUSH_IMAGE
}

test_validate_runtime_inputs_rejects_invalid_push_image_value() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export PUSH_IMAGE="sometimes"

  if validate_runtime_inputs >/dev/null 2>&1; then
    fail "expected validate_runtime_inputs to reject invalid PUSH_IMAGE values"
  fi

  unset PUSH_IMAGE
}

test_validate_bootstrap_tools_requires_early_commands() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local commands=()
  require_command() { commands+=("$1"); }
  docker() { :; }

  validate_bootstrap_tools

  assert_eq "${commands[*]}" "apt-get awk bash chroot cp docker mount mountpoint sudo umount"
}

test_validate_bootstrap_tools_fails_without_docker_daemon_access() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local docker_calls=()
  require_command() { :; }
  docker() {
    docker_calls+=("$*")
    [[ "$1" == "info" ]] && return 1
    return 0
  }

  if validate_bootstrap_tools >/dev/null 2>&1; then
    fail "expected validate_bootstrap_tools to fail when docker daemon access is unavailable"
  fi

  assert_eq "${docker_calls[*]}" "info"
}

test_validate_bootstrap_tools_fails_without_buildx() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local docker_calls=()
  require_command() { :; }
  docker() {
    docker_calls+=("$*")
    [[ "${1:-} ${2:-}" == "buildx version" ]] && return 1
    return 0
  }

  if validate_bootstrap_tools >/dev/null 2>&1; then
    fail "expected validate_bootstrap_tools to fail when docker buildx is unavailable"
  fi

  assert_eq "${docker_calls[*]}" "info buildx version"
}

test_validate_host_tools_requires_full_command_set() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local commands=()
  require_command() { commands+=("$1"); }
  docker() { :; }

  validate_host_tools

  assert_eq "${commands[*]}" "apt-get awk bash chroot cp docker mount mountpoint sudo umount e2fsck growpart kpartx parted qemu-aarch64-static qemu-img resize2fs sha256sum wget xz"
}

test_mount_guest_filesystems_mounts_root_before_creating_efi_dir() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  LOOP_DEVICE="/dev/loop7"

  local sudo_calls=()
  sudo() { sudo_calls+=("$*"); }
  log_step() { :; }

  mount_guest_filesystems

  assert_eq "${sudo_calls[0]}" "mkdir -p /mnt/rpi_root"
  assert_eq "${sudo_calls[1]}" "mount /dev/mapper/loop7p2 /mnt/rpi_root"
  assert_eq "${sudo_calls[2]}" "mkdir -p /mnt/rpi_root/boot/efi"
  assert_eq "${sudo_calls[3]}" "mount /dev/mapper/loop7p1 /mnt/rpi_root/boot/efi"
}

test_convert_to_qcow2_writes_disc_qcow2() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  IMAGE_FILE="2026-06-18-raspios-trixie-arm64-lite.img"

  local qemu_args=""
  qemu-img() { qemu_args="$*"; }
  log_step() { :; }

  convert_to_qcow2

  assert_eq "${qemu_args}" "convert -f raw -O qcow2 2026-06-18-raspios-trixie-arm64-lite.img disc.qcow2"
}

test_download_source_image_verifies_pinned_checksum_before_extracting() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local calls=()
  local checksum_input=""
  rm() { calls+=("rm:$*"); }
  wget() { calls+=("wget:$*"); }
  sha256sum() {
    calls+=("sha256sum:$*")
    checksum_input="$(cat)"
  }
  xz() { calls+=("xz:$*"); }
  log_step() { :; }

  download_source_image

  assert_eq "${IMG_SHA256}" "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
  assert_eq "${calls[*]}" "rm:-f 2026-06-18-raspios-trixie-arm64-lite.img.xz 2026-06-18-raspios-trixie-arm64-lite.img disc.qcow2 disk.qcow2 wget:-q -O 2026-06-18-raspios-trixie-arm64-lite.img.xz https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz sha256sum:-c - xz:-d 2026-06-18-raspios-trixie-arm64-lite.img.xz"
  assert_eq "${checksum_input}" "acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3  2026-06-18-raspios-trixie-arm64-lite.img.xz"
}

test_download_source_image_stops_before_extracting_when_checksum_fails() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  local calls=()
  rm() { calls+=("rm:$*"); }
  wget() { calls+=("wget:$*"); }
  sha256sum() {
    calls+=("sha256sum:$*")
    cat >/dev/null
    return 1
  }
  xz() { calls+=("xz:$*"); }
  log_step() { :; }

  if download_source_image >/dev/null 2>&1; then
    fail "expected download_source_image to fail when checksum verification fails"
  fi

  assert_eq "${calls[*]}" "rm:-f 2026-06-18-raspios-trixie-arm64-lite.img.xz 2026-06-18-raspios-trixie-arm64-lite.img disc.qcow2 disk.qcow2 wget:-q -O 2026-06-18-raspios-trixie-arm64-lite.img.xz https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz sha256sum:-c -"
}

test_build_containerdisk_image_pushes_with_repository_dockerfile() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

  local docker_calls=()
  docker() {
    docker_calls+=("$*")
    if [[ "$1" == "login" ]]; then
      cat >/dev/null
    fi
  }
  log_step() { :; }

  build_containerdisk_image "ghcr.io/example/raspios:test"

  assert_eq "${docker_calls[0]}" "login ghcr.io -u demo-user --password-stdin"
  assert_eq "${docker_calls[1]}" "buildx build --platform linux/arm64 -t ghcr.io/example/raspios:test --push ."
}

test_build_containerdisk_image_validates_without_publishing_when_push_disabled() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export PUSH_IMAGE=false

  local docker_calls=()
  docker() { docker_calls+=("$*"); }
  log_step() { :; }

  build_containerdisk_image "ghcr.io/example/raspios:test"

  assert_eq "${#docker_calls[@]}" "1"
  assert_eq "${docker_calls[0]}" "buildx build --platform linux/arm64 -t ghcr.io/example/raspios:test --load ."
  unset PUSH_IMAGE
}

test_source_fails_for_readonly_fixed_source_constants() {
  local output status
  if output="$(
    bash -lc 'readonly IMG_URL="https://example.invalid/bad.img.xz"; source "$1"' _ "${SCRIPT_PATH}" 2>&1
  )"; then
    status=0
  else
    status=$?
  fi

  [[ "${status}" -ne 0 ]] || fail "expected sourcing to fail when IMG_URL is readonly"
  [[ "${output}" == *"IMG_URL"* ]] || fail "expected failure output to mention IMG_URL, got: ${output}"
}

test_workflow_uses_new_script() {
  grep -Fq 'run: bash ./build-raspios-lite-containerdisk.sh' "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow is not using the new script"
}

test_workflow_restricts_publish_to_trusted_main_pushes() {
  local validate_job publish_job
  validate_job="$(extract_job_block "validate-raspberry-pi-containerdisk")"
  publish_job="$(extract_job_block "publish-raspberry-pi-containerdisk")"

  printf '%s\n' "${validate_job}" | grep -Fxq "    if: github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'" \
    || fail "validation job is not restricted to non-publish pull_request/workflow_dispatch events"
  assert_contains "${validate_job}" "persist-credentials: false"
  assert_contains "${validate_job}" "PUSH_IMAGE: 'false'"
  assert_not_contains "${validate_job}" "packages: write"
  assert_not_contains "${validate_job}" "GHCR_TOKEN"
  assert_not_contains "${validate_job}" "GITHUB_TOKEN"

  printf '%s\n' "${publish_job}" | grep -Fxq "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
    || fail "publish job is not restricted to trusted main pushes"
  assert_contains "${publish_job}" "packages: write"
  assert_contains "${publish_job}" "id: image-tag"
  assert_contains "${publish_job}" "docker/login-action@v3"
  assert_contains "${publish_job}" "default_image_tag"
  assert_contains "${publish_job}" "password: \${{ secrets.GITHUB_TOKEN }}"
  assert_contains "${publish_job}" "PUSH_IMAGE: 'false'"
  assert_contains "${publish_job}" 'docker push "${{ steps.image-tag.outputs.value }}"'
  assert_not_contains "${publish_job}" "GHCR_TOKEN"
}

test_workflow_publish_job_authenticates_only_after_secret_free_build() {
  local publish_job build_line login_line push_line
  publish_job="$(extract_job_block "publish-raspberry-pi-containerdisk")"
  build_line="$(line_number_of "${publish_job}" "run: bash ./build-raspios-lite-containerdisk.sh")"
  login_line="$(line_number_of "${publish_job}" "name: Login to GitHub Container Registry")"
  push_line="$(line_number_of "${publish_job}" 'run: docker push "${{ steps.image-tag.outputs.value }}"')"

  [[ -n "${build_line}" ]] || fail "publish job is missing the secret-free build step"
  [[ -n "${login_line}" ]] || fail "publish job is missing the registry login step"
  [[ -n "${push_line}" ]] || fail "publish job is missing the docker push step"
  [[ "${build_line}" -lt "${login_line}" ]] || fail "publish job authenticates before the secret-free build step"
  [[ "${login_line}" -lt "${push_line}" ]] || fail "publish job does not push after authenticating"
}

test_workflow_publish_job_has_single_login_step() {
  local publish_job login_step_count
  publish_job="$(extract_job_block "publish-raspberry-pi-containerdisk")"
  login_step_count="$(printf '%s\n' "${publish_job}" | grep -Fc 'name: Login to GitHub Container Registry' || true)"
  assert_eq "${login_step_count}" "1"
}

test_workflow_renames_docker_compose_references() {
  ! grep -Eq 'Docker Compose|docker-compose|run-docker-compose' "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow still contains Docker Compose names"
}

test_readme_documents_new_script() {
  local readme
  readme="$(<"${ROOT_DIR}/README.md")"

  grep -Fq 'build-raspios-lite-containerdisk.sh' "${ROOT_DIR}/README.md" \
    || fail "README does not document the new script"
  grep -Fq 'disc.qcow2' "${ROOT_DIR}/README.md" \
    || fail "README does not document the disc.qcow2 artifact"
  grep -Fq '/disk/disk.qcow2' "${ROOT_DIR}/README.md" \
    || fail "README does not document the packaged /disk/disk.qcow2 path"
  assert_contains "${readme}" 'GHCR_USERNAME` and `GHCR_TOKEN` are required only when publishing'
  assert_contains "${readme}" 'Set `PUSH_IMAGE=false` to validate the build without publishing'
}

test_dockerfile_packages_disc_at_kubevirt_path() {
  local dockerfile
  dockerfile="$(<"${ROOT_DIR}/Dockerfile")"
  assert_contains "${dockerfile}" 'ADD --chown=107:107 ./disc.qcow2 /disk/disk.qcow2'
}

test_main_runs_all_stages_in_order
test_main_stops_before_qcow2_when_unmount_fails
test_main_prefers_image_tag_override
test_validate_runtime_inputs_skips_ghcr_credentials_when_push_disabled
test_validate_runtime_inputs_rejects_invalid_push_image_value
test_validate_bootstrap_tools_requires_early_commands
test_validate_bootstrap_tools_fails_without_docker_daemon_access
test_validate_bootstrap_tools_fails_without_buildx
test_validate_host_tools_requires_full_command_set
test_mount_guest_filesystems_mounts_root_before_creating_efi_dir
test_convert_to_qcow2_writes_disc_qcow2
test_download_source_image_verifies_pinned_checksum_before_extracting
test_download_source_image_stops_before_extracting_when_checksum_fails
test_build_containerdisk_image_pushes_with_repository_dockerfile
test_build_containerdisk_image_validates_without_publishing_when_push_disabled
test_source_fails_for_readonly_fixed_source_constants
test_workflow_uses_new_script
test_workflow_restricts_publish_to_trusted_main_pushes
test_workflow_publish_job_authenticates_only_after_secret_free_build
test_workflow_publish_job_has_single_login_step
test_workflow_renames_docker_compose_references
test_readme_documents_new_script
test_dockerfile_packages_disc_at_kubevirt_path

echo "PASS"
