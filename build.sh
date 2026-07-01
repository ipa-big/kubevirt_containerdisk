#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: required environment variable '${var_name}' is not set." >&2
    exit 1
  fi
}

require_env "IMG_URL"
require_env "IMG_NAME"
require_env "IMG_PLATFORM"

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  require_env "GHCR_USERNAME"
  require_env "GHCR_TOKEN"
fi

sudo apt-get update -qq > /dev/null 2>&1
sudo apt-get install -qq -y qemu-utils kpartx dosfstools qemu-user-static > /dev/null 2>&1

# Download image
wget -q ${IMG_URL}

# Decompress image
xz -d *.xz

# Expand image
qemu-img resize *.img +2G

# Loop device mapping
sudo kpartx -av *.img

# Extend partition
sudo growpart /dev/loop0 2
sudo kpartx -u *.img
sudo parted /dev/loop0 set 1 esp on
sudo e2fsck -fp /dev/mapper/loop0p2 || sudo e2fsck -fy /dev/mapper/loop0p2
sudo resize2fs /dev/mapper/loop0p2

# Mount
sudo mkdir -p /mnt/rpi_root
sudo mount /dev/mapper/loop0p2 /mnt/rpi_root
sudo mkdir -p /mnt/rpi_root/boot/efi
sudo mount /dev/mapper/loop0p1 /mnt/rpi_root/boot/efi

sudo cp /usr/bin/qemu-aarch64-static /mnt/rpi_root/usr/bin/

sudo mount --bind /dev /mnt/rpi_root/dev
sudo mount --bind /proc /mnt/rpi_root/proc
sudo mount --bind /sys /mnt/rpi_root/sys
sudo mount --bind /run /mnt/rpi_root/run

sudo chroot /mnt/rpi_root /bin/bash -eux <<EOF
apt-get update -qq
apt-get install -qq -y linux-image-arm64 grub-efi-arm64

grep -qxF 'virtio' /etc/initramfs-tools/modules || echo 'virtio' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_blk' /etc/initramfs-tools/modules || echo 'virtio_blk' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_pci' /etc/initramfs-tools/modules || echo 'virtio_pci' >> /etc/initramfs-tools/modules
grep -qxF 'virtio_net' /etc/initramfs-tools/modules || echo 'virtio_net' >> /etc/initramfs-tools/modules
update-initramfs -u -k --all

grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
update-grub

sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200 rootwait"/' /etc/default/grub

# Ensure serial terminal settings exist for both GRUB menu and kernel console use.
if grep -q '^GRUB_TERMINAL_INPUT=' /etc/default/grub; then
  sed -i 's/^GRUB_TERMINAL_INPUT=.*/GRUB_TERMINAL_INPUT="console serial"/' /etc/default/grub
else
  echo 'GRUB_TERMINAL_INPUT="console serial"' >> /etc/default/grub
fi

if grep -q '^GRUB_TERMINAL_OUTPUT=' /etc/default/grub; then
  sed -i 's/^GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="console serial"/' /etc/default/grub
else
  echo 'GRUB_TERMINAL_OUTPUT="console serial"' >> /etc/default/grub
fi

if grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub; then
  sed -i 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"/' /etc/default/grub
else
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
fi

update-grub

BOOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p1)
ROOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p2)

cp /etc/fstab /etc/fstab.bak

cat << FSTAB > /etc/fstab
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$BOOT_UUID /boot/efi vfat defaults 0 2
FSTAB

rm -rf /boot/firmware
EOF

sudo umount /mnt/rpi_root/dev /mnt/rpi_root/proc /mnt/rpi_root/sys /mnt/rpi_root/run
sudo umount /mnt/rpi_root/boot/efi /mnt/rpi_root

qemu-img convert -f raw -O qcow2 *.img disc.qcow2

# Build containerdisk
IMAGE_TAG="ghcr.io/ipa-big/kubevirt_containerdisk/${IMG_NAME}_uefi"

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" --push .
else
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" .
fi

echo "Image built: ${IMAGE_TAG}"