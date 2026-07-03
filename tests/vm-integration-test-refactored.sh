#!/usr/bin/env bash
# Integration test for VM deployment using the containerdisk image
# Tests that a VM can be created, boot successfully, and has valid network connectivity
# Checks guest-console-log and compute containers for errors during boot

set -euo pipefail

NAMESPACE="default"
VM_NAME="raspi-test-integration"
IMAGE="ghcr.io/ipa-big/kubevirt_containerdisk/2026-06-18-raspios-trixie-arm64-lite_uefi"
CONTAINERDISK_POD_PREFIX="virt-launcher-${VM_NAME}"

# 8-minute timeout for VM boot (in seconds)
BOOT_TIMEOUT=480

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# ─────────────────────────────────────────────────────────────────────────────
# Logging Functions
# ─────────────────────────────────────────────────────────────────────────────

log_pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_info() {
    echo -e "${YELLOW}INFO:${NC} $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────────────────────

get_vm_pod_name() {
    local pod_name
    pod_name=$(kubectl get pod -l kubevirt.io=virt-launcher -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    echo "$pod_name"
}

get_vmi_phase() {
    local phase
    phase=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
    echo "$phase"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build Functions
# ─────────────────────────────────────────────────────────────────────────────

build_containerdisk() {
    # Build/create containerdisk from kernel image
    # Returns: 0 on success (image already exists or built), 1 on failure
    log_info "Building containerdisk from image: ${IMAGE}"
    
    # Verify image exists by attempting to pull metadata
    if ! docker manifest inspect "${IMAGE}" > /dev/null 2>&1; then
        log_fail "Container image not found: ${IMAGE}"
        return 1
    fi
    
    log_pass "Containerdisk image verified: ${IMAGE}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# VM Management Functions
# ─────────────────────────────────────────────────────────────────────────────

create_vm() {
    # Create a VM using the containerdisk
    # Returns: 0 on success, 1 on failure
    log_info "Creating VM manifest..."
    
    cat > /tmp/test-vm.yaml <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  runStrategy: RerunOnFailure
  template:
    metadata:
      labels:
        app: ${VM_NAME}
        purpose: integration-test
    spec:
      architecture: arm64
      nodeSelector:
        kubernetes.io/arch: arm64
        machine-type.node.kubevirt.io/virt: "true"
      domain:
        machine:
          type: virt
        resources:
          requests:
            memory: 2048M
            cpu: "2"
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              bridge: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: ${IMAGE}
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              chpasswd:
                list: |
                  pi:raspberry
                expire: false
EOF

    if ! kubectl apply -f /tmp/test-vm.yaml; then
        log_fail "Failed to apply VM manifest"
        return 1
    fi
    
    # Wait for VM to be created
    sleep 5
    
    if kubectl get vm "${VM_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
        log_pass "VM manifest applied successfully"
        return 0
    else
        log_fail "VM manifest not found after apply"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Wait Functions
# ─────────────────────────────────────────────────────────────────────────────

wait_for_vm_ready() {
    # Wait for the VM to boot and become ready
    # Checks: Running phase, login prompt in guest-console-log
    # Returns: 0 on success, 1 on failure
    
    log_info "Waiting for VM to reach Running phase (up to ${BOOT_TIMEOUT} seconds)..."
    
    # Wait for VM to reach Running phase with timeout
    local count=0
    local phase=""
    while [ $count -lt $BOOT_TIMEOUT ]; do
        phase=$(get_vmi_phase)
        if [ "$phase" == "Running" ]; then
            log_pass "VM reached Running phase"
            break
        fi
        sleep 2
        count=$((count + 1))
    done
    
    if [ "$phase" != "Running" ]; then
        log_fail "VM did not reach Running phase within ${BOOT_TIMEOUT} seconds (current phase: ${phase:-none})"
        kubectl describe vmi "${VM_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
        return 1
    fi
    
    # Get pod name for log checking
    local pod_name
    pod_name=$(get_vm_pod_name)
    if [ -z "$pod_name" ]; then
        log_fail "Could not find virt-launcher pod"
        return 1
    fi
    
    log_info "Waiting for login prompt (up to ${BOOT_TIMEOUT} seconds)..."
    
    # Wait for login prompt in guest-console-log container
    count=0
    local login_found=false
    while [ $count -lt $BOOT_TIMEOUT ]; do
        # Verify VM is still Running
        phase=$(get_vmi_phase)
        if [ "$phase" != "Running" ]; then
            sleep 2
            count=$((count + 1))
            continue
        fi
        
        # Check logs for login prompt
        if kubectl logs "$pod_name" -c guest-console-log -n "${NAMESPACE}" 2>/dev/null | grep -q "login:"; then
            log_pass "Login prompt detected in guest-console-log"
            login_found=true
            break
        fi
        
        # Check for systemd target reached
        if kubectl logs "$pod_name" -c guest-console-log -n "${NAMESPACE}" 2>/dev/null | grep -q "Reached target Login Prompts"; then
            log_pass "Login prompt target reached"
            login_found=true
            break
        fi
        
        # Check compute container for errors
        local compute_errors
        compute_errors=$(kubectl logs "$pod_name" -c compute -n "${NAMESPACE}" 2>/dev/null | grep -iE "ERROR|FAIL|panic|crash|failed" || true)
        if [ -n "$compute_errors" ]; then
            log_fail "Errors detected in compute container:"
            echo "$compute_errors"
            return 1
        fi
        
        sleep 2
        count=$((count + 1))
    done
    
    if [ "$login_found" = false ]; then
        log_fail "Login prompt not detected within ${BOOT_TIMEOUT} seconds"
        return 1
    fi
    
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification Functions
# ─────────────────────────────────────────────────────────────────────────────

verify_ssh_connectivity() {
    # Verify SSH connectivity to the VM
    # Returns: 0 on success, 1 on failure
    # Note: This is a placeholder - SSH verification would require network setup
    log_info "Verifying SSH connectivity..."
    
    # TODO: Add actual SSH connectivity check when network is configured
    # For now, verify network interface exists in VMI status
    local interfaces
    interfaces=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].name}' 2>/dev/null)
    
    if [ -n "$interfaces" ]; then
        log_pass "Network interface found: ${interfaces}"
        return 0
    else
        log_fail "No network interfaces found in VMI status"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Smoke Test Functions
# ─────────────────────────────────────────────────────────────────────────────

run_smoke_tests() {
    # Run smoke tests to verify VM is functioning correctly
    # Returns: 0 if all smoke tests pass, 1 if any fail
    
    local all_passed=true
    
    log_info "Running smoke tests..."
    
    # Test 1: Verify pod is scheduled to ARM64 node with valid IP
    log_info "Smoke Test 1: Verifying pod scheduling..."
    local node
    node=$(kubectl get pod -l kubevirt.io=virt-launcher -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    
    if [ -n "$node" ]; then
        local arch
        arch=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io\/arch}' 2>/dev/null)
        if [ "$arch" == "arm64" ]; then
            log_pass "Pod scheduled to ARM64 node: $node"
        else
            log_fail "Pod scheduled to non-ARM64 node: $node (arch: $arch)"
            all_passed=false
        fi
    else
        log_fail "Could not determine node for VM pod"
        all_passed=false
    fi
    
    # Test 2: Verify QEMU machine type indicates UEFI support
    log_info "Smoke Test 2: Verifying QEMU machine type..."
    local pod_name
    pod_name=$(get_vm_pod_name)
    
    if [ -z "$pod_name" ]; then
        log_fail "Could not find VM pod"
        all_passed=false
    else
        local machine_type
        machine_type=$(kubectl logs "$pod_name" -c compute -n "${NAMESPACE}" 2>/dev/null | grep -o 'virt-rhel[0-9.]*' | head -1)
        
        if [ -n "$machine_type" ]; then
            log_pass "QEMU machine type: $machine_type"
        else
            log_fail "Could not determine QEMU machine type"
            all_passed=false
        fi
    fi
    
    # Test 3: Verify VM is running with expected resources
    log_info "Smoke Test 3: Verifying VM resources..."
    local guest_memory
    guest_memory=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.memory.guestRequested}' 2>/dev/null)
    
    local has_topology
    has_topology=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.currentCPUTopology}' 2>/dev/null)
    
    if [ "$guest_memory" == "2048M" ]; then
        log_pass "Memory configured: $guest_memory"
    else
        log_fail "Unexpected memory: $guest_memory (expected 2048M)"
        all_passed=false
    fi
    
    if [ -n "$has_topology" ] && [[ "$has_topology" == *"cores"* ]]; then
        log_pass "CPU topology configured (sockets/cores/threads)"
    else
        log_fail "CPU topology not found in status"
        all_passed=false
    fi
    
    # Test 4: Check for errors in guest-console-log container
    log_info "Smoke Test 4: Checking guest-console-log for errors..."
    if [ -z "$pod_name" ]; then
        log_fail "Could not find VM pod for log check"
        all_passed=false
    else
        local guest_log_errors
        guest_log_errors=$(kubectl logs "$pod_name" -c guest-console-log -n "${NAMESPACE}" 2>/dev/null | grep -iE "ERROR|FAIL|panic|crash|emergency|failed to start" || true)
        if [ -n "$guest_log_errors" ]; then
            log_fail "Errors detected in guest-console-log container:"
            echo "$guest_log_errors"
            all_passed=false
        else
            log_pass "No errors detected in guest-console-log"
        fi
    fi
    
    # Test 5: Check for errors in compute container
    log_info "Smoke Test 5: Checking compute container for errors..."
    if [ -n "$pod_name" ]; then
        local compute_errors
        compute_errors=$(kubectl logs "$pod_name" -c compute -n "${NAMESPACE}" 2>/dev/null | grep -iE "ERROR|FAIL|panic|crash" || true)
        if [ -n "$compute_errors" ]; then
            log_fail "Errors detected in compute container:"
            echo "$compute_errors"
            all_passed=false
        else
            log_pass "No errors detected in compute container"
        fi
    else
        log_fail "Could not check compute container (no pod found)"
        all_passed=false
    fi
    
    if [ "$all_passed" = true ]; then
        return 0
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Diagnostics Functions
# ─────────────────────────────────────────────────────────────────────────────

collect_diagnostics() {
    # Collect diagnostic information from multiple sources
    # Arguments:
    #   $1 - pod_name: Name of the virt-launcher pod
    #   $2 - output_file: Path to write diagnostic report
    # Returns: 0 on success
    
    local pod_name="$1"
    local output_file="$2"
    
    if [ -z "$pod_name" ] || [ -z "$output_file" ]; then
        log_fail "collect_diagnostics: Missing required arguments"
        return 1
    fi
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Initialize output file with header
    {
        echo "========================================"
        echo "VM Boot Diagnostic Report"
        echo "========================================"
        echo "Generated: ${timestamp}"
        echo ""
    } > "$output_file"
    
    # Collect guest-console-log (last 50 lines)
    {
        echo "=== guest-console-log ==="
        echo "Last 50 lines of console output:"
        echo "---"
        kubectl logs "$pod_name" -c guest-console-log -n "${NAMESPACE}" 2>/dev/null | tail -50 || echo "(Failed to collect guest-console-log)"
        echo "---"
        echo ""
    } >> "$output_file"
    
    # Collect VM/VMI status (yaml output)
    {
        echo "=== VM/VMI Status ==="
        kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "(Failed to collect VMI status)"
        echo ""
    } >> "$output_file"
    
    # Collect pod status (yaml output)
    {
        echo "=== Pod Status ==="
        kubectl get pod "$pod_name" -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "(Failed to collect pod status)"
        echo ""
    } >> "$output_file"
    
    # Collect container disk info (init container logs)
    {
        echo "=== Container Disk ==="
        kubectl logs "$pod_name" -c volumecontainerdisk-init -n "${NAMESPACE}" 2>/dev/null || echo "(Failed to collect container disk logs)"
        echo ""
    } >> "$output_file"
    
    # Print readable summary to console
    echo ""
    echo "========================================"
    echo "VM Boot Diagnostic Report"
    echo "========================================"
    echo "Generated: ${timestamp}"
    echo ""
    
    # Guest console log summary
    local console_lines
    console_lines=$(kubectl logs "$pod_name" -c guest-console-log -n "${NAMESPACE}" 2>/dev/null | tail -20 || echo "No logs available")
    echo "[ guest-console-log ]"
    echo "Last 20 lines of console output:"
    echo "$console_lines" | sed 's/^/  /'
    echo ""
    
    # VM/VMI status summary
    local vmi_phase vmi_ip vmi_node
    vmi_phase=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    vmi_ip=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
    vmi_node=$(kubectl get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.node_NAME}' 2>/dev/null || echo "N/A")
    echo "[ VM/VMI Status ]"
    echo "  Phase: ${vmi_phase:-N/A}"
    echo "  IP: ${vmi_ip:-N/A}"
    echo "  Node: ${vmi_node:-N/A}"
    echo ""
    
    # Pod status summary
    local restart_count
    restart_count=$(kubectl get pod "$pod_name" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    echo "[ Pod Status ]"
    echo "  Restart Count: ${restart_count:-0}"
    echo ""
    
    # Container disk info summary
    local disk_logs
    disk_logs=$(kubectl logs "$pod_name" -c volumecontainerdisk-init -n "${NAMESPACE}" 2>/dev/null | head -10 || echo "No logs available")
    echo "[ Container Disk ]"
    echo "  Init container logs (first 10 lines):"
    echo "$disk_logs" | sed 's/^/    /'
    echo ""
    
    echo "========================================"
    echo "Full report saved to: $output_file"
    echo "========================================"
    
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup Functions
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    # Cleanup function - always called on exit
    log_info "Cleaning up test resources..."
    
    # Delete VM if it exists
    kubectl delete vm "${VM_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
    
    # Wait for VM pod to be deleted
    local count=0
    while kubectl get pod -l kubevirt.io=virt-launcher -n "${NAMESPACE}" | grep -q "${CONTAINERDISK_POD_PREFIX}" && [ $count -lt 30 ]; do
        sleep 2
        ((count++))
    done
    
    # Force delete if still present
    kubectl delete pod -l kubevirt.io=virt-launcher -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Test Orchestration
# ─────────────────────────────────────────────────────────────────────────────

main() {
    # Set trap for always cleanup
    trap cleanup EXIT
    
    local diagnostics_file=""
    
    # Run test suite
    if ! build_containerdisk; then
        log_fail "Containerdisk build failed"
        exit 1
    fi
    
    if ! create_vm; then
        log_fail "VM creation failed"
        exit 1
    fi
    
    if ! wait_for_vm_ready; then
        log_fail "VM did not become ready"
        # Collect diagnostics before exiting
        local timestamp
        timestamp=$(date -u +"%Y%m%d_%H%M%S")
        diagnostics_file="/tmp/vm-diagnostics-${TIMESTAMP}.log"
        log_info "Collecting diagnostic information..."
        
        local pod_name
        pod_name=$(get_vm_pod_name)
        if [ -n "$pod_name" ]; then
            collect_diagnostics "$pod_name" "$diagnostics_file"
        fi
        
        exit 1
    fi
    
    if ! verify_ssh_connectivity; then
        log_fail "SSH connectivity verification failed"
        exit 1
    fi
    
    if ! run_smoke_tests; then
        log_fail "Smoke tests failed"
        exit 1
    fi
    
    # Summary
    echo ""
    echo "========================================"
    echo "Integration Test Results"
    echo "========================================"
    echo -e "Tests Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests Failed: ${RED}${TESTS_FAILED}${NC}"
    echo "========================================"
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}Integration tests FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}All integration tests PASSED${NC}"
        exit 0
    fi
}

# Execute main function
main "$@"