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

test_main_runs_all_stages_in_order() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

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

test_main_stops_before_qcow2_when_unmount_fails() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

  local calls=()
  validate_runtime_inputs() { calls+=("validate_runtime_inputs"); }
  validate_host_tools() { calls+=("validate_host_tools"); }
  install_host_dependencies() { calls+=("install_host_dependencies"); }
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

  assert_eq "${calls[*]}" "validate_runtime_inputs validate_host_tools install_host_dependencies download_source_image expand_and_map_image mount_guest_filesystems convert_guest_image unmount_guest_filesystems"
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

test_workflow_validates_pull_requests_without_publishing() {
  grep -Fq "PUSH_IMAGE: \${{ github.event_name != 'pull_request' }}" "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow does not disable publishing on pull_request events"
  ! grep -Fq 'head.repo.full_name == github.repository' "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow still special-cases same-repo pull requests instead of validating all pull requests without publishing"
}

test_workflow_renames_docker_compose_references() {
  ! grep -Eq 'Docker Compose|docker-compose|run-docker-compose' "${ROOT_DIR}/.github/workflows/main.yml" \
    || fail "workflow still contains Docker Compose names"
}

test_readme_documents_new_script() {
  grep -Fq 'build-raspios-lite-containerdisk.sh' "${ROOT_DIR}/README.md" \
    || fail "README does not document the new script"
  grep -Fq 'disc.qcow2' "${ROOT_DIR}/README.md" \
    || fail "README does not document the disc.qcow2 artifact"
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
test_mount_guest_filesystems_mounts_root_before_creating_efi_dir
test_convert_to_qcow2_writes_disc_qcow2
test_build_containerdisk_image_pushes_with_repository_dockerfile
test_build_containerdisk_image_validates_without_publishing_when_push_disabled
test_source_fails_for_readonly_fixed_source_constants
test_workflow_uses_new_script
test_workflow_validates_pull_requests_without_publishing
test_workflow_renames_docker_compose_references
test_readme_documents_new_script
test_dockerfile_packages_disc_at_kubevirt_path

echo "PASS"
