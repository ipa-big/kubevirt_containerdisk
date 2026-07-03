## Raspberry Pi OS containerdisk build

Use `build-raspios-lite-containerdisk.sh` to build a KubeVirt-ready containerdisk from the fixed Raspberry Pi OS image `2026-06-18-raspios-trixie-arm64-lite.img.xz`.

### VM Kernel Panic Fix

This containerdisk includes fixes for running Raspberry Pi OS in KubeVirt on ARM64 nodes:

- **ACPI Support:** Added `acpi=force` kernel parameter to enable ACPI-based boot in KubeVirt VMs
- **Console Configuration:** Changed from `serial0` to `ttyAMA0` for proper serial console output
- **Timer Calibration:** Added `no_timer_check` to skip timer calibration that may fail in VMs
- **Graphics Overlay:** Disabled `vc4-kms-v3d` overlay that conflicts with VM graphics
- **Fallback:** Created `cmdline_acpi_fallback.txt` with `acpi=ht` for reduced ACPI functionality

If the primary boot with `acpi=force` fails, copy `cmdline_acpi_fallback.txt` to `cmdline.txt` to use the fallback configuration.

### Required environment variables

- `IMAGE_TAG_OVERRIDE` (optional)
- `PUSH_IMAGE` (optional, defaults to `true`; set to `false` to validate without publishing)

`GHCR_USERNAME` and `GHCR_TOKEN` are required only when publishing.

### Local usage

Set `PUSH_IMAGE=false` to validate the build without publishing:

```bash
export PUSH_IMAGE=false
bash ./build-raspios-lite-containerdisk.sh
```

To publish to GHCR, export `GHCR_USERNAME` and `GHCR_TOKEN`, then leave `PUSH_IMAGE` unset (or set it to `true`) before running the script.

The script runs a lightweight boot smoke validation before publishing.
Install `qemu-efi-aarch64` so the smoke validation can boot with ARM64 UEFI firmware.
The smoke validation uses disposable UEFI vars and QEMU snapshot mode, so `disc.qcow2` remains pristine for packaging.

The script generates `disc.qcow2` and packages it at `/disk/disk.qcow2`, ready to use as a KubeVirt containerdisk.

## References

| Titel                                                               | URL                                                                                  |
|---------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| UEFI auf dem Raspberry Pi                                           | https://www.linux-community.de/ausgaben/linuxuser/2025/10/uefi-auf-dem-raspberry-pi/ |
| Raspberry Pi Firmware                                               | https://github.com/raspberrypi/firmware                                              |
| Raspberry Pi 4 UEFI Firmware Images                                 | https://github.com/pftf/RPi4                                                         |
| firmware development environment for the UEFI and PI specifications | https://github.com/tianocore/edk2                                                    |
| Raspberry Pi 4 UEFI won't boot                                      | https://github.com/pftf/RPi4/issues/178                                              |

### Troubleshooting

#### VM Still Crashes with Kernel Panic

If your VM still crashes after applying this fix:

1. Check the VM's kernel logs using `kubectl logs <pod-name>`
2. Verify the containerdisk image tag is correct
3. Try using the fallback cmdline: Copy `cmdline_acpi_fallback.txt` to `cmdline.txt`
4. Ensure your KubeVirt VM configuration uses the correct machine type

#### Smoke Validation Fails

The smoke validation checks if the VM boots successfully. If it fails:

1. Check the VM's serial console output for kernel panic messages
2. Verify the containerdisk was built with the ACPI fix
3. Ensure your KubeVirt cluster has sufficient resources (at least 1GB RAM)
4. Try deploying with increased timeout in the VM manifest
