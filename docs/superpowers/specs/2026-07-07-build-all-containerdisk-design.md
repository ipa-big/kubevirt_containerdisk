# Build All Containerdisk Design

**Date:** 2026-07-07  
**Author:** Copilot  
**Status:** Approved

## Overview

Add the ability to build both Trixie and Bookworm containerdisk images in a single script execution using the `BUILD_ALL=true` environment variable.

## Current Behavior

- `BUILD_TARGET=trixie` (default): Build Trixie containerdisk
- `BUILD_TARGET=bookworm`: Build Bookworm containerdisk
- `PUSH_IMAGE=true` (default): Push the built image to GHCR
- `PUSH_IMAGE=false`: Build locally without pushing

## New Behavior

- `BUILD_ALL=true`: Build both Trixie and Bookworm sequentially
- When `BUILD_ALL=true`, `PUSH_IMAGE` applies to each image individually
- Fail-fast: Stop if any build fails
- Each image is pushed independently after its build succeeds
- When `BUILD_ALL` is unset or `false`, preserve existing `BUILD_TARGET` behavior

## Implementation

### New Function: `build_single_containerdisk()`

Extract the common build logic into a reusable function:

```bash
build_single_containerdisk() {
  local img_name="$1"
  local image_tag="${IMAGE_TAG_OVERRIDE:-$(default_image_tag)}"
  # ... rest of build steps
}
```

This function:
- Takes the image name constant as parameter (`IMG_NAME` or `BOOKWORM_IMG_NAME`)
- Uses `default_image_tag()` which dynamically extracts the tag from the image name
- Performs all build steps for that specific image variant

### Modified Main Flow

When `BUILD_ALL=true`:
1. Log: "Building both Trixie and Bookworm containerdisk images"
2. Call `build_single_containerdisk "$IMG_NAME"` (Trixie)
3. On success, call `build_single_containerdisk "$BOOKWORM_IMG_NAME"` (Bookworm)
4. On failure, stop and report error

### Backward Compatibility

When `BUILD_ALL` is unset or `false`:
- Preserve existing behavior using `BUILD_TARGET` variable
- Default to Trixie if `BUILD_TARGET` is not set

## Image Naming

**Trixie image:**
- Image name: `ghcr.io/ipa-big/kubevirt_containerdisk/raspios-trixie-arm64-lite`
- Tag: `YYYY-MM-DD` (extracted from filename)
- Example: `ghcr.io/ipa-big/kubevirt_containerdisk/raspios-trixie-arm64-lite:2026-06-18`

**Bookworm image:**
- Image name: `ghcr.io/ipa-big/kubevirt_containerdisk/raspios-bookworm-arm64-lite`
- Tag: `YYYY-MM-DD` (extracted from filename)
- Example: `ghcr.io/ipa-big/kubevirt_containerdisk/raspios-bookworm-arm64-lite:2026-06-18`

## Testing

### Unit Tests
- Add `test_build_all_builds_both_images` - verifies both builds run when `BUILD_ALL=true`
- Add `test_build_all_fails_fast_on_first_error` - verifies failure stops execution
- Add `test_build_single_containerdisk_with_different_images` - tests helper function

### Integration Tests
- Update existing tests to use new helper function
- Add integration test for `BUILD_ALL` mode

## CI/CD Impact

The GitHub Actions workflow should continue working without changes:
- Uses `default_image_tag()` which handles both Trixie and Bookworm
- `BUILD_ALL` is an optional flag that doesn't affect the default behavior

## Environment Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `BUILD_ALL` | boolean | `false` | When `true`, build both Trixie and Bookworm |
| `BUILD_TARGET` | string | `trixie` | When `BUILD_ALL=false`, which image to build |
| `IMAGE_TAG_OVERRIDE` | string | auto-generated | Override the auto-generated image tag |
| `PUSH_IMAGE` | boolean | `true` | Whether to push the built image(s) |

## Success Criteria

- [ ] `BUILD_ALL=true` builds both Trixie and Bookworm images
- [ ] Fail-fast behavior: stops on first build failure
- [ ] Each image pushes independently after successful build
- [ ] Backward compatible: existing `BUILD_TARGET` behavior unchanged
- [ ] All existing tests pass
- [ ] New tests added for `BUILD_ALL` functionality
- [ ] Documentation updated in README.md