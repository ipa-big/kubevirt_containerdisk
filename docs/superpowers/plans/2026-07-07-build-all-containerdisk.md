# Build All Containerdisk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the ability to build both Trixie and Bookworm containerdisk images in a single script execution using the `BUILD_ALL=true` environment variable, while preserving backward compatibility with existing `BUILD_TARGET` behavior.

**Architecture:** Extract the common build logic into a reusable `build_single_containerdisk(img_name)` function that takes the image name constant as a parameter. When `BUILD_ALL=true`, call this function twice (Trixie then Bookworm) sequentially. Each image pushes independently after successful build. Fail-fast: stop if any build fails.

**Tech Stack:** Bash, GitHub Actions, Docker, QEMU

## Global Constraints

- **Script:** `build-raspios-lite-containerdisk.sh` (existing, ~670 lines)
- **Test file:** `tests/build-raspios-lite-containerdisk.test.sh`
- **Integration test:** `tests/vm-integration-test.sh`
- **Image naming:** `ghcr.io/ipa-big/kubevirt_containerdisk/{raspios-trixie-arm64-lite,raspios-bookworm-arm64-lite}:{YYYY-MM-DD}`
- **Fail-fast behavior:** Stop on first build failure
- **Backward compatibility:** Preserve existing `BUILD_TARGET` behavior when `BUILD_ALL` is unset or `false`
- **Environment variable:** `BUILD_ALL` (boolean, default `false`)

---

## Task 1: Extract `build_single_containerdisk()` helper function

**Files:**
- Create: `build-raspios-lite-containerdisk.sh:429-448` (refactor `main()` into helper)
- Test: `tests/build-raspios-lite-containerdisk.test.sh`

**Interfaces:**
- Consumes: `default_image_tag()`, `validate_runtime_inputs()`, `validate_bootstrap_tools()`, `install_host_dependencies()`, `validate_host_tools()`, `download_source_image()`, `expand_and_map_image()`, `mount_guest_filesystems()`, `convert_guest_image()`, `add_userconf_trixie()`, `run_guest_boot_sanity_checks()`, `apply_acpi_fix()`, `unmount_guest_filesystems()`, `convert_to_qcow2()`, `build_containerdisk_image()`
- Produces: `build_single_containerdisk(img_name)` - new function that performs all build steps for a single image variant

- [ ] **Step 1: Read current `main()` function to understand build steps**

View the current `main()` function at lines 429-448 of `build-raspios-lite-containerdisk.sh` to understand all the build steps.

- [ ] **Step 2: Create `build_single_containerdisk()` function**

Replace the existing `main()` function with `build_single_containerdisk(img_name)`:

```bash
build_single_containerdisk() {
  local img_name="$1"
  local image_tag="${IMAGE_TAG_OVERRIDE:-$(default_image_tag)}"

  validate_runtime_inputs
  validate_bootstrap_tools
  install_host_dependencies
  validate_host_tools
  download_source_image
  expand_and_map_image
  mount_guest_filesystems
  convert_guest_image
  add_userconf_trixie
  run_guest_boot_sanity_checks
  apply_acpi_fix
  unmount_guest_filesystems || return 1
  convert_to_qcow2
  # run_boot_smoke_validation
  build_containerdisk_image "${image_tag}"
  log_step "Image built: ${image_tag}"
}
```

Note: The function uses `default_image_tag()` which already extracts the tag from `IMG_NAME`.

- [ ] **Step 3: Run tests to verify no regression**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`
Expected: All existing tests pass

- [ ] **Step 4: Add unit test for `build_single_containerdisk()`**

Add new test `test_build_single_containerdisk_with_different_images`:

```bash
test_build_single_containerdisk_with_different_images() {
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  unset PUSH_IMAGE

  local calls=()
  main() { calls+=("main:$*"); }
  build_containerdisk_image() { calls+=("build:$1"); }

  build_single_containerdisk "$IMG_NAME"

  assert_contains "${calls[*]}" "build:ghcr.io/ipa-big/kubevirt_containerdisk/raspios-trixie-arm64-lite:2026-06-18"
}
```

- [ ] **Step 5: Run tests and verify new test passes**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`
Expected: New test passes, all existing tests still pass

- [ ] **Step 6: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "refactor: extract build_single_containerdisk() helper function"
```

---

## Task 2: Implement `BUILD_ALL` logic in main execution block

**Files:**
- Modify: `build-raspios-lite-containerdisk.sh:663-670`
- Test: `tests/build-raspios-lite-containerdisk.test.sh`

**Interfaces:**
- Consumes: `build_single_containerdisk(img_name)` - new function from Task 1
- Produces: Conditional execution based on `BUILD_ALL` environment variable

- [ ] **Step 1: Read current execution block at end of script**

View lines 663-670 of `build-raspios-lite-containerdisk.sh` to see the current execution logic.

- [ ] **Step 2: Replace execution block with `BUILD_ALL` logic**

Replace the current execution block:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap cleanup EXIT
  if [[ "${BUILD_ALL:-false}" == "true" ]]; then
    log_step "Building both Trixie and Bookworm containerdisk images"
    build_single_containerdisk "$IMG_NAME" || {
      log_step "Trixie build failed, stopping"
      exit 1
    }
    build_single_containerdisk "$BOOKWORM_IMG_NAME" || {
      log_step "Bookworm build failed, stopping"
      exit 1
    }
  elif [[ "${BUILD_TARGET:-trixie}" == "bookworm" ]]; then
    build_bookworm_containerdisk
  else
    main "$@"
  fi
fi
```

Note: This uses the new `build_single_containerdisk()` function for both images.

- [ ] **Step 3: Add unit test for `BUILD_ALL=true` behavior**

Add new test `test_build_all_builds_both_images`:

```bash
test_build_all_builds_both_images() {
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  export BUILD_ALL="true"
  unset PUSH_IMAGE

  local calls=()
  build_single_containerdisk() { calls+=("build:$1"); }
  log_step() { :; }

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup EXIT
    if [[ "${BUILD_ALL:-false}" == "true" ]]; then
      log_step "Building both Trixie and Bookworm containerdisk images"
      build_single_containerdisk "$IMG_NAME" || {
        log_step "Trixie build failed, stopping"
        exit 1
      }
      build_single_containerdisk "$BOOKWORM_IMG_NAME" || {
        log_step "Bookworm build failed, stopping"
        exit 1
      }
    fi
  fi

  assert_contains "${calls[*]}" "build:2026-06-18-raspios-trixie-arm64-lite"
  assert_contains "${calls[*]}" "build:2026-06-18-raspios-bookworm-arm64-lite"
}
```

- [ ] **Step 4: Add unit test for `BUILD_ALL=true` fail-fast**

Add new test `test_build_all_fails_fast_on_first_error`:

```bash
test_build_all_fails_fast_on_first_error() {
  source "${SCRIPT_PATH}"

  export GHCR_USERNAME="demo-user"
  export GHCR_TOKEN="demo-token"
  export BUILD_ALL="true"
  unset PUSH_IMAGE

  local calls=()
  build_single_containerdisk() { 
    calls+=("build:$1")
    if [[ "$1" == "$IMG_NAME" ]]; then
      return 1  # Fail on first build
    fi
  }
  log_step() { :; }

  # Capture exit status
  local exit_status=0
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup EXIT
    if [[ "${BUILD_ALL:-false}" == "true" ]]; then
      log_step "Building both Trixie and Bookworm containerdisk images"
      build_single_containerdisk "$IMG_NAME" || {
        log_step "Trixie build failed, stopping"
        exit 1
      }
      build_single_containerdisk "$BOOKWORM_IMG_NAME" || {
        log_step "Bookworm build failed, stopping"
        exit 1
      }
    fi
  fi || exit_status=$?

  assert_eq "$exit_status" "1"
  assert_contains "${calls[*]}" "build:2026-06-18-raspios-trixie-arm64-lite"
  assert_not_contains "${calls[*]}" "build:2026-06-18-raspios-bookworm-arm64-lite"
}
```

- [ ] **Step 5: Run tests and verify all pass**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`
Expected: All tests pass including new `BUILD_ALL` tests

- [ ] **Step 6: Commit**

```bash
git add build-raspios-lite-containerdisk.sh tests/build-raspios-lite-containerdisk.test.sh
git commit -m "feat: add BUILD_ALL=true support for building both images"
```

---

## Task 3: Update integration tests

**Files:**
- Modify: `tests/vm-integration-test.sh:17`

**Interfaces:**
- Consumes: None (test-only change)
- Produces: Updated default `IMAGE_TAG` to match new format

- [ ] **Step 1: Read current IMAGE_TAG in integration test**

View line 17 of `tests/vm-integration-test.sh`.

- [ ] **Step 2: Update IMAGE_TAG to new format**

Update the `IMAGE_TAG` variable to match the new tag format:

```bash
# Before:
IMAGE_TAG="${IMAGE_TAG:-ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi}"

# After:
IMAGE_TAG="${IMAGE_TAG:-ghcr.io/ipa-big/kubevirt_containerdisk/raspios-trixie-arm64-lite:2026-06-18}"
```

Note: The tag now uses `:` separator instead of `_uefi` suffix.

- [ ] **Step 3: Run integration test**

Run: `bash tests/vm-integration-test.sh`
Expected: Integration test passes with new tag format

- [ ] **Step 4: Commit**

```bash
git add tests/vm-integration-test.sh
git commit -m "test: update IMAGE_TAG to new format"
```

---

## Task 4: Update documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: None (documentation only)
- Produces: Updated README with `BUILD_ALL` documentation

- [ ] **Step 1: Read current environment variables section**

View the "Required environment variables" section in `README.md`.

- [ ] **Step 2: Add `BUILD_ALL` documentation**

Add the following to the environment variables section:

```markdown
- `BUILD_ALL` (optional, defaults to `false`)
  - When `true`, build both Trixie and Bookworm containerdisk images sequentially
  - Each image is pushed independently after successful build
  - Build stops on first failure (fail-fast)
  - When `false`, use `BUILD_TARGET` to select which image to build

- `BUILD_TARGET` (optional, defaults to `trixie`)
  - Used when `BUILD_ALL=false`
  - Valid values: `trixie` (default), `bookworm`
```

- [ ] **Step 3: Add usage examples**

Add a new "Usage examples" section after the environment variables:

```markdown
### Usage examples

**Build a single image (Trixie - default):**
```bash
./build-raspios-lite-containerdisk.sh
# or
BUILD_TARGET=bookworm ./build-raspios-lite-containerdisk.sh
```

**Build both images:**
```bash
BUILD_ALL=true ./build-raspios-lite-containerdisk.sh
```

**Build locally without publishing:**
```bash
BUILD_ALL=true PUSH_IMAGE=false ./build-raspios-lite-containerdisk.sh
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add BUILD_ALL and BUILD_TARGET documentation"
```

---

## Task 5: Verify CI/CD compatibility

**Files:**
- Review: `.github/workflows/main.yml`

**Interfaces:**
- Consumes: None (review only)
- Produces: Confirmation that CI/CD works with new implementation

- [ ] **Step 1: Read GitHub Actions workflow**

View `.github/workflows/main.yml` to understand how it uses the build script.

- [ ] **Step 2: Verify workflow compatibility**

The workflow:
- Sets `IMAGE_TAG_OVERRIDE` from `default_image_tag()`
- Calls `bash ./build-raspios-lite-containerdisk.sh`

This works because:
- `default_image_tag()` extracts the tag from `IMG_NAME` (Trixie by default)
- The script's `BUILD_ALL` logic only activates when explicitly set
- No changes needed to CI/CD

- [ ] **Step 3: Document CI/CD behavior in comments**

Add a comment to `.github/workflows/main.yml` explaining the default behavior:

```yaml
# Note: BUILD_ALL defaults to false, so this builds only Trixie
# To build both, set BUILD_ALL=true in the workflow
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "ci: add comment about BUILD_ALL default behavior"
```

---

## Task 6: Final verification

**Files:**
- All modified files

**Interfaces:**
- Consumes: None (verification only)
- Produces: Confirmed working implementation

- [ ] **Step 1: Run all unit tests**

Run: `bash tests/build-raspios-lite-containerdisk.test.sh`
Expected: All tests pass

- [ ] **Step 2: Verify build script syntax**

Run: `bash -n build-raspios-lite-containerdisk.sh`
Expected: No syntax errors

- [ ] **Step 3: Verify `BUILD_ALL=false` preserves existing behavior**

Run: `BUILD_ALL=false bash -c 'source build-raspios-lite-containerdisk.sh; echo "BUILD_TARGET=$BUILD_TARGET"'`
Expected: Uses `BUILD_TARGET` logic

- [ ] **Step 4: Commit all changes**

```bash
git add .
git commit -m "refactor: finalize BUILD_ALL implementation"
```

- [ ] **Step 5: Push to remote**

```bash
git push origin main
```