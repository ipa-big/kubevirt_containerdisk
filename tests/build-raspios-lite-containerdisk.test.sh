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

test_convert_to_qcow2_writes_disk_qcow2() {
  # shellcheck disable=SC1090
  source "${SCRIPT_PATH}"

  IMAGE_FILE="2026-06-18-raspios-trixie-arm64-lite.img"

  local qemu_args=""
  qemu-img() { qemu_args="$*"; }
  log_step() { :; }

  convert_to_qcow2

  assert_eq "${qemu_args}" "convert -f raw -O qcow2 2026-06-18-raspios-trixie-arm64-lite.img disk.qcow2"
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

test_main_runs_all_stages_in_order
test_main_prefers_image_tag_override
test_convert_to_qcow2_writes_disk_qcow2
test_source_fails_for_readonly_fixed_source_constants

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

echo "PASS"
