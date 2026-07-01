FROM scratch
# 107:107 is the default qemu user/group ID inside the KubeVirt pod launcher
ADD --chown=107:107 ./disc.qcow2 /disk/disk.qcow2
