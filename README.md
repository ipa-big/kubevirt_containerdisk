## Raspberry Pi OS containerdisk build

Use `build-raspios-lite-containerdisk.sh` to build a KubeVirt-ready containerdisk from the fixed Raspberry Pi OS image `2026-06-18-raspios-trixie-arm64-lite.img.xz`.

### Required environment variables

- `GHCR_USERNAME`
- `GHCR_TOKEN`
- `IMAGE_TAG_OVERRIDE` (optional)
- `PUSH_IMAGE` (optional, defaults to `true`; set to `false` to validate without publishing)

### Local usage

```bash
export GHCR_USERNAME=your-github-user
export GHCR_TOKEN=your-ghcr-token
export PUSH_IMAGE=false
bash ./build-raspios-lite-containerdisk.sh
```

The script generates `disc.qcow2` and packages it at `/disk/disk.qcow2`, ready to use as a KubeVirt containerdisk. Leave `PUSH_IMAGE` unset (or `true`) to publish to GHCR.

## References

| Titel                                                               | URL                                                                                  |
|---------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| UEFI auf dem Raspberry Pi                                           | https://www.linux-community.de/ausgaben/linuxuser/2025/10/uefi-auf-dem-raspberry-pi/ |
| Raspberry Pi Firmware                                               | https://github.com/raspberrypi/firmware                                              |
| Raspberry Pi 4 UEFI Firmware Images                                 | https://github.com/pftf/RPi4                                                         |
| firmware development environment for the UEFI and PI specifications | https://github.com/tianocore/edk2                                                    |
| Raspberry Pi 4 UEFI won't boot                                      | https://github.com/pftf/RPi4/issues/178                                              |
