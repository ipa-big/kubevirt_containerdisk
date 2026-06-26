#!/usr/bin/env bash

# Download image
wget ${IMG_URL}

# Decompress image
xz -d *.xz

# Convert image to qcow2 format
qemu-img convert -f raw -O qcow2 *.img disk.qcow2

# Build containerdisk
IMAGE_TAG="ghcr.io/ipa-big/kubevirt_containerdisk/${IMG_NAME}"

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" --push .
else
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" .
fi