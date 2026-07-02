#!/usr/bin/env bash
set -euo pipefail

# Define fixed image constants (override caller-set variables, but remain safe to re-source)
# If the variable exists and is readonly (from a prior source), leave it as-is.
# Otherwise unset any caller-provided value and set our readonly constant.
if declare -p IMG_URL >/dev/null 2>&1; then
  if ! declare -p IMG_URL 2>/dev/null | grep -q "declare -r"; then
    unset IMG_URL || true
    readonly IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
  fi
else
  readonly IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
fi

if declare -p IMG_NAME >/dev/null 2>&1; then
  if ! declare -p IMG_NAME 2>/dev/null | grep -q "declare -r"; then
    unset IMG_NAME || true
    readonly IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
  fi
else
  readonly IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
fi

if declare -p IMG_PLATFORM >/dev/null 2>&1; then
  if ! declare -p IMG_PLATFORM 2>/dev/null | grep -q "declare -r"; then
    unset IMG_PLATFORM || true
    readonly IMG_PLATFORM="linux/arm64"
  fi
else
  readonly IMG_PLATFORM="linux/arm64"
fi

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
