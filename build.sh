#!/usr/bin/env bash

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
sudo e2fsck -f /dev/mapper/loop0p2
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

sudo chroot /mnt/rpi_root

apt-get update -qq
apt install -y linux-image-arm64 grub-efi-arm64
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
update-grub

BOOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p1)
ROOT_UUID=$(blkid -o value -s UUID /dev/mapper/loop0p2)

cp /etc/fstab /etc/fstab.bak

cat << EOF > /etc/fstab
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$BOOT_UUID /boot/efi vfat defaults 0 2
EOF

rm -rf /boot/firmware

exit

umount /mnt/rpi_root/dev /mnt/rpi_root/proc /mnt/rpi_root/sys /mnt/rpi_root/run
umount /mnt/rpi_root/boot/efi /mnt/rpi_root

qemu-img convert -f raw -O qcow2 *.img disc.qcow2

# Build containerdisk
IMAGE_TAG="ghcr.io/ipa-big/kubevirt_containerdisk/${IMG_NAME}_uefi"

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" --push .
else
  docker buildx build --platform "${IMG_PLATFORM}" -t "${IMAGE_TAG}" .
fi