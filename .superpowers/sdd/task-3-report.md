Task 3 report

Implemented lightweight boot smoke validation, added the required host-tool checks, and documented the pre-publish validation step.

Tests:
- bash tests/build-raspios-lite-containerdisk.test.sh
- bash -n build-raspios-lite-containerdisk.sh
- grep -n "validate-raspberry-pi-containerdisk" .github/workflows/main.yml

Commit:
- d368bff

Fix report:
- Updated `build-raspios-lite-containerdisk.sh` so `run_boot_smoke_validation()` treats a login prompt as success even when `timeout` exits nonzero, matching the expected healthy-boot behavior.
- Added `qemu-system-arm` to `install_host_dependencies()` so clean runners can install the system emulator required by `qemu-system-aarch64`.
- Covering test file: `tests/build-raspios-lite-containerdisk.test.sh`
- Commands run and output:
  - `bash tests/build-raspios-lite-containerdisk.test.sh` → `PASS`
  - `bash -n build-raspios-lite-containerdisk.sh` → no output, exit 0
