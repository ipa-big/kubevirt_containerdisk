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
