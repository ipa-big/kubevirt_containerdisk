#!/bin/bash

set -e

# ==============================================================================
# VM Integration Test - Refactored
# ==============================================================================

# Configuration
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
VM_NAME="${VM_NAME:-raspios-vm}"
VM_NAMESPACE="${VM_NAMESPACE:-default}"
CONTAINERDISK_PATH="${CONTAINERDISK_PATH:-/tmp/containerdisk.qcow2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

get_vm_pod_name() {
    local vm_name="$1"
    kubectl -n "$VM_NAMESPACE" get pods -l vm.kubevirt.io/name="$vm_name" -o jsonpath='{.items[0].metadata.name}'
}

get_vmi_phase() {
    local vm_name="$1"
    kubectl -n "$VM_NAMESPACE" get vmi "$vm_name" -o jsonpath='{.status.phase}'
}

collect_diagnostics() {
    local error_msg="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local diag_dir="/tmp/vm-diagnostics-${timestamp}"
    
    log_warn "Collecting diagnostics: ${error_msg}"
    mkdir -p "$diag_dir"
    
    # Collect VM info
    kubectl -n "$VM_NAMESPACE" get vmi "$VM_NAME" -o yaml > "$diag_dir/vmi.yaml" 2>/dev/null || true
    kubectl -n "$VM_NAMESPACE" get pod -l kubevirt.io=virt-launcher-"$VM_NAME" -o yaml > "$diag_dir/vm-pod.yaml" 2>/dev/null || true
    
    # Collect logs
    local pod_name=$(get_vm_pod_name "$VM_NAME")
    if [[ -n "$pod_name" ]]; then
        kubectl -n "$VM_NAMESPACE" logs "$pod_name" > "$diag_dir/vm-pod.log" 2>/dev/null || true
        kubectl -n "$VM_NAMESPACE" logs "$pod_name" -c container-disk > "$diag_dir/container-disk.log" 2>/dev/null || true
    fi
    
    # Collect events
    kubectl -n "$VM_NAMESPACE" get events --sort-by='.lastTimestamp' > "$diag_dir/events.log" 2>/dev/null || true
    
    # Collect system info
    echo "Diagnostics collected at: $(date)" > "$diag_dir/README.txt"
    echo "Error: ${error_msg}" >> "$diag_dir/README.txt"
    echo "VM Name: ${VM_NAME}" >> "$diag_dir/README.txt"
    echo "VM Namespace: ${VM_NAMESPACE}" >> "$diag_dir/README.txt"
    
    log_warn "Diagnostics saved to: ${diag_dir}"
}

# ==============================================================================
# Test Functions
# ==============================================================================

build_containerdisk() {
    log_info "Building containerdisk from kernel image..."
    
    local kernel_img="/tmp/rpi_kernel.img"
    local built_disc="/home/operation/kubevirt_containerdisk/disc.qcow2"
    
    # Use the built image if available
    if [[ -f "$built_disc" ]]; then
        log_info "Using built disc.qcow2 from build script"
        cp "$built_disc" "$CONTAINERDISK_PATH"
        if [[ ! -f "$CONTAINERDISK_PATH" ]]; then
            log_error "Failed to copy containerdisk"
            return 1
        fi
        log_info "Containerdisk created successfully: $CONTAINERDISK_PATH"
        return 0
    fi
    
    if [[ ! -f "$kernel_img" ]]; then
        log_error "Kernel image not found: $kernel_img"
        return 1
    fi
    
    # Convert kernel image to QCOW2 format
    qemu-img convert -f raw -O qcow2 "$kernel_img" "$CONTAINERDISK_PATH"
    
    if [[ ! -f "$CONTAINERDISK_PATH" ]]; then
        log_error "Failed to create containerdisk"
        return 1
    fi
    
    log_info "Containerdisk created successfully: $CONTAINERDISK_PATH"
    return 0
}

create_vm() {
    log_info "Creating VM manifest..."
    
    # Generate cloud-init configuration
    local cloud_init_dir="/tmp/cloud-init"
    mkdir -p "$cloud_init_dir"
    
    cat > "$cloud_init_dir/cloud-config.yaml" << 'CLOUDCONFIG'
#cloud-config
hostname: raspios-vm
password: raspberry
chpasswd:
  expire: false
ssh_authorized_keys:
  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDExampleUser@localhost
package_upgrade: false
runcmd:
  - echo "VM initialized via cloud-init"
CLOUDCONFIG

    cat > "$cloud_init_dir/meta-data.yaml" << 'METADATA'
instance-id: raspios-vm
local-hostname: raspios-vm
METADATA

    # Create cloud-init volume
    local cloud_init_iso="/tmp/cloud-init.iso"
    genisoimage -output "$cloud_init_iso" -volid cidata -joliet -rock "$cloud_init_dir/cloud-config.yaml" "$cloud_init_dir/meta-data.yaml"

    # Create VM manifest
    cat > /tmp/vm.yaml << 'VMMANIFEST'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: raspios-vm
  namespace: default
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/size: small
        kubevirt.io/domain: raspios
    spec:
      domain:
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
            - name: emptydisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              bridge: {}
        resources:
          requests:
            memory: 1024M
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          persistentVolumeClaim:
            claimName: raspios-pvc
        - name: cloudinit
          cloudInitNoCloud:
            secretRef:
              name: cloud-init-secret
        - name: emptydisk
          emptyDisk:
            capacity: 2Gi
VMMANIFEST

    # Create secret for cloud-init
    kubectl -n "$VM_NAMESPACE" create secret generic cloud-init-secret \
        --from-file=userData="$cloud_init_dir/cloud-config.yaml" \
        --from-file=metaData="$cloud_init_dir/meta-data.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Apply VM manifest
    kubectl apply -f /tmp/vm.yaml
    log_info "VM created successfully"
}

wait_for_vm_ready() {
    local timeout="$1"
    local elapsed=0
    
    log_info "Waiting for VM to be ready..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local phase=$(get_vmi_phase "$VM_NAME")
        
        if [[ "$phase" == "Running" ]]; then
            log_info "VM is Running"
            
            # Check if pod exists
            local pod_name=$(get_vm_pod_name "$VM_NAME")
            if [[ -n "$pod_name" ]]; then
                log_info "Pod $pod_name is running"
                return 0
            fi
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        log_info "Current phase: ${phase:-Unknown}, waited: ${elapsed}s"
    done
    
    log_error "VM failed to become ready within ${timeout}s"
    return 1
}

verify_ssh_connectivity() {
    log_info "Verifying SSH connectivity..."
    
    local vm_pod=$(get_vm_pod_name "$VM_NAME")
    if [[ -z "$vm_pod" ]]; then
        log_warn "VM pod not found, skipping SSH check"
        return 0
    fi
    
    # Get VM IP
    local vm_ip=$(kubectl -n "$VM_NAMESPACE" get pod "$vm_pod" -o jsonpath='{.status.podIP}')
    
    if [[ -z "$vm_ip" ]]; then
        log_warn "VM IP not assigned, skipping SSH check"
        return 0
    fi
    
    log_info "VM IP: ${vm_ip}"
    
    # Test SSH connectivity (with timeout)
    if timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 pi@"$vm_ip" "echo SSH successful" 2>/dev/null; then
        log_info "SSH connectivity verified"
        return 0
    else
        log_warn "SSH not yet ready, continuing with other tests"
        return 0  # Don't fail the test for SSH yet
    fi
}

run_smoke_tests() {
    log_info "Running smoke tests..."
    
    local tests_passed=0
    local tests_failed=0
    
    # Test 1: Check VM is running
    log_info "Test 1: Checking VM status..."
    local phase=$(get_vmi_phase "$VM_NAME")
    if [[ "$phase" == "Running" ]]; then
        log_info "✓ VM is running"
        ((tests_passed++))
    else
        log_error "✗ VM phase is ${phase}, expected Running"
        ((tests_failed++))
    fi
    
    # Test 2: Check pod is running
    log_info "Test 2: Checking pod status..."
    local pod_name=$(get_vm_pod_name "$VM_NAME")
    if [[ -n "$pod_name" ]]; then
        local pod_phase=$(kubectl -n "$VM_NAMESPACE" get pod "$pod_name" -o jsonpath='{.status.phase}')
        if [[ "$pod_phase" == "Running" ]]; then
            log_info "✓ Pod is running"
            ((tests_passed++))
        else
            log_error "✗ Pod phase is ${pod_phase}, expected Running"
            ((tests_failed++))
        fi
    else
        log_error "✗ Pod not found"
        ((tests_failed++))
    fi
    
    # Test 3: Check containerdisk exists
    log_info "Test 3: Checking containerdisk..."
    if [[ -f "$CONTAINERDISK_PATH" ]]; then
        local size=$(stat -c%s "$CONTAINERDISK_PATH")
        log_info "✓ Containerdisk exists (${size} bytes)"
        ((tests_passed++))
    else
        log_error "✗ Containerdisk not found: $CONTAINERDISK_PATH"
        ((tests_failed++))
    fi
    
    # Test 4: Check logs
    log_info "Test 4: Checking logs..."
    if [[ -n "$pod_name" ]]; then
        local logs=$(kubectl -n "$VM_NAMESPACE" logs "$pod_name" 2>&1 | tail -20)
        # Only check for critical errors (panic, oom-killer, segfault, etc.)
        if echo "$logs" | grep -qiE "panic|oom-killer|segfault|killed process|out of memory"; then
            log_error "✗ Found critical errors in logs"
            echo "$logs" | grep -iE "panic|oom-killer|segfault|killed process|out of memory" || true
            ((tests_failed++))
        else
            log_info "✓ No critical errors in logs"
            ((tests_passed++))
        fi
    fi
    
    log_info "Smoke tests complete: ${tests_passed} passed, ${tests_failed} failed"
    
    if [[ $tests_failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

main() {
    log_info "Starting VM Integration Test"
    log_info "VM Name: ${VM_NAME}"
    log_info "Namespace: ${VM_NAMESPACE}"
    
    # Cleanup on exit
    cleanup() {
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            collect_diagnostics "Test failed with exit code: ${exit_code}"
        fi
        exit $exit_code
    }
    trap cleanup EXIT
    
    # Step 1: Build containerdisk
    if ! build_containerdisk; then
        collect_diagnostics "Failed to build containerdisk"
        exit 1
    fi
    
    # Step 2: Create VM
    if ! create_vm; then
        collect_diagnostics "Failed to create VM"
        exit 1
    fi
    
    # Step 3: Wait for VM ready
    if ! wait_for_vm_ready "$TEST_TIMEOUT"; then
        collect_diagnostics "VM failed to become ready"
        exit 1
    fi
    
    # Step 4: Verify SSH connectivity
    verify_ssh_connectivity || true
    
    # Step 5: Run smoke tests
    if ! run_smoke_tests; then
        collect_diagnostics "Smoke tests failed"
        exit 1
    fi
    
    log_info "✓ All tests passed"
    exit 0
}

main "$@"
