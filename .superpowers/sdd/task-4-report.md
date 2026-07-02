Task 4 report

Summary
-------
Implemented CI wiring and README documentation for the dedicated Raspberry Pi containerdisk builder.

Changes made
------------
- tests/build-raspios-lite-containerdisk.test.sh: added two failing tests (workflow uses new script, README documents new script) and executed them.
- .github/workflows/main.yml: replaced the build step to call `bash ./build-raspios-lite-containerdisk.sh` and removed unused IMG_* and PUSH_IMAGE env entries.
- README.md: replaced with user-facing documentation describing the fixed source image, required env vars, local usage, and that the image contains `disc.qcow2` at `/disk/disk.qcow2`.

TDD steps performed
-------------------
1. Wrote failing tests and ran the test script (expected failure):
   - Command: bash /home/operation/kubevirt_containerdisk/.worktrees/raspberry-pi-containerdisk-build/tests/build-raspios-lite-containerdisk.test.sh
   - Observed: FAIL with message "workflow is not using the new script"
2. Implemented minimal changes to .github/workflows/main.yml and README.md.
3. Re-ran tests:
   - Observed: PASS
4. Verified presence of expected lines in the files:
   - Found `run: bash ./build-raspios-lite-containerdisk.sh` in .github/workflows/main.yml
   - README contains `build-raspios-lite-containerdisk.sh`, `GHCR_USERNAME`, and `GHCR_TOKEN`

Commits
-------
- de610f88fe30b057967f8f5600f6241dc607e5ef  docs: wire CI and usage for dedicated Raspberry Pi builder
  Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>

Validation commands run
-----------------------
- bash /home/operation/kubevirt_containerdisk/.worktrees/raspberry-pi-containerdisk-build/tests/build-raspios-lite-containerdisk.test.sh
- grep -n "run: bash ./build-raspios-lite-containerdisk.sh" .github/workflows/main.yml
- grep -n "GHCR_USERNAME" README.md
- grep -n "GHCR_TOKEN" README.md
- grep -n "build-raspios-lite-containerdisk.sh" README.md

Self-review / Concerns
----------------------
- All changes are localized to the worktree branch `raspberry-pi-containerdisk-build` as requested.
- The workflow now invokes the local script and relies on the repo-provided script; it assumes the script is executable/works in GitHub Actions (Ubuntu) as intended by earlier tasks.
- `rg` was not available in the execution environment; used `grep` instead for verification.

No further actions required unless the CI environment requires additional secrets or permission changes.

Fix applied
-----------
- Modified `.github/workflows/main.yml` to run GHCR login and build only when not a pull_request or when the pull_request head repo matches the repository (same-repo PR). Replaced `if: github.event_name != 'pull_request'` with `if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository` on the Login and Run steps. This preserves CI coverage for same-repo PRs while avoiding GHCR push attempts on forked PRs.

Covering tests and commands run
------------------------------
- Test files:
  - tests/build-raspios-lite-containerdisk.test.sh

- Commands executed:
  - bash /home/operation/kubevirt_containerdisk/.worktrees/raspberry-pi-containerdisk-build/tests/build-raspios-lite-containerdisk.test.sh
  - grep -n "run: bash ./build-raspios-lite-containerdisk.sh" .github/workflows/main.yml
  - grep -n "GHCR_USERNAME" README.md
  - grep -n "GHCR_TOKEN" README.md
  - grep -n "build-raspios-lite-containerdisk.sh" README.md

- Output:

PASS
33:        run: bash ./build-raspios-lite-containerdisk.sh
7:- `GHCR_USERNAME`
14:export GHCR_USERNAME=your-github-user
8:- `GHCR_TOKEN`
15:export GHCR_TOKEN=your-ghcr-token
3:Use `build-raspios-lite-containerdisk.sh` to build a KubeVirt-ready containerdisk from the fixed Raspberry Pi OS image `2026-06-18-raspios-trixie-arm64-lite.img.xz`.
16:bash ./build-raspios-lite-containerdisk.sh

Validation notes
----------------
- The change preserves behavior for push and workflow_dispatch events and restores CI coverage for same-repo pull_request events while avoiding image push attempts during forked pull_request runs.
