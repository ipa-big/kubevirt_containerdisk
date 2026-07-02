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
