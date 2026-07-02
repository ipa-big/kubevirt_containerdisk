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
