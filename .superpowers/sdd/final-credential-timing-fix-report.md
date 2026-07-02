# Final Credential Timing Fix Report

## Summary
Closed the remaining whole-branch review finding by moving GHCR authentication out of the guest conversion path. The publish job now performs the full Raspberry Pi image download/conversion/container build without registry credentials, then authenticates afterward and pushes the already-built image.

## Root cause
The trusted-main publish job exported `GHCR_USERNAME` and `GHCR_TOKEN` into the same `build-raspios-lite-containerdisk.sh` invocation that performs image mounts, chrooted package installation, GRUB changes, and qcow2 conversion. That made the registry secret available in the process environment during the highest-risk guest-manipulation stages.

## Fix applied
1. `.github/workflows/main.yml`
   - Added a `Resolve containerdisk image tag` step that sources `build-raspios-lite-containerdisk.sh` and captures `default_image_tag` into a workflow output.
   - Moved the full `bash ./build-raspios-lite-containerdisk.sh` run ahead of registry login and forced it into secret-free mode with `PUSH_IMAGE='false'`.
   - Passed `IMAGE_TAG_OVERRIDE` from the resolved tag output so the later push step targets the exact image built in the secret-free step.
   - Replaced the credentialed script invocation with a narrow `docker push "${{ steps.image-tag.outputs.value }}"` step after `docker/login-action@v3`.
2. `tests/build-raspios-lite-containerdisk.test.sh`
   - Updated workflow assertions to require the publish job to resolve the tag, keep `PUSH_IMAGE='false'`, omit `GHCR_TOKEN`, and push via a separate `docker push` step.
   - Added an ordering regression test that proves the secret-free build runs before registry login and that push happens only after authentication.

## Scope notes
- `build.sh` was left unchanged.
- PR/manual validation behavior stays unchanged: it still runs with `PUSH_IMAGE=false` and no GHCR credentials.
- Trusted-main publish gating stays unchanged: publishing still requires a `push` on `refs/heads/main` with `packages: write`.

## Verification
Executed in the worktree:

```bash
bash tests/build-raspios-lite-containerdisk.test.sh
bash -n tests/build-raspios-lite-containerdisk.test.sh
git --no-pager diff --check
```

Observed results:
- workflow/test regression suite: `PASS`
- bash syntax check: exit 0
- diff whitespace check: exit 0
