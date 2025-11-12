#!/usr/bin/env bash

# Script to deploy N RHEL9 VMs with unique names and configure them
# Usage: ./add-vms.sh [number_of_vms]
# Default: 1 VM

set -uo pipefail  # Note: not using -e due to parallel execution

# Global variables
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
NAMESPACE="${NAMESPACE:-openshift-cnv}"
SSH_USER="${SSH_USER:-cloud-user}"
VM_PASSWORD="${VM_PASSWORD:-password}"
VM_PREFIX="${VM_PREFIX:-rhel9}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-registry.redhat.io/rhel9/rhel-guest-image:latest}"
NUM_VMS=0

# SSH keys for cloud-init
SSH_KEYS=(
	"ssh-ed25519 AAAA... person1@example.com"
	"ssh-ed25519 AAAA... person2@example.com"
)

# Check prerequisites
check_prerequisites() {
	echo "Checking prerequisites..."

	if ! command -v kubectl &> /dev/null; then
		echo "ERROR: kubectl is not installed or not in PATH"
		exit 1
	fi

	if ! command -v virtctl &> /dev/null; then
		echo "ERROR: virtctl is not installed or not in PATH"
		echo "Install it with: kubectl krew install virt"
		exit 1
	fi

	if ! kubectl cluster-info &> /dev/null; then
		echo "ERROR: Cannot connect to Kubernetes cluster"
		exit 1
	fi

	if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
		echo "ERROR: Namespace '$NAMESPACE' does not exist"
		echo "Create it or set NAMESPACE environment variable"
		exit 1
	fi

	if [ -f "$SCRIPT_DIR/setup-vm.sh" ]; then
		if [ ! -x "$SCRIPT_DIR/setup-vm.sh" ]; then
			echo "WARNING: setup-vm.sh exists but is not executable"
			echo "Making it executable..."
			chmod +x "$SCRIPT_DIR/setup-vm.sh"
		fi
	else
		echo "WARNING: setup-vm.sh not found at $SCRIPT_DIR/setup-vm.sh"
		echo "VMs will be created but not configured"
	fi

	echo "Prerequisites OK"
	echo ""
}

# Validate and parse number of VMs argument
parse_arguments() {
	local num_vms_arg="${1:-1}"
	
	if ! [[ "$num_vms_arg" =~ ^[0-9]+$ ]] || [ "$num_vms_arg" -lt 1 ]; then
		echo "ERROR: Please provide a valid positive number"
		echo "Usage: $0 [number_of_vms]"
		exit 1
	fi

	NUM_VMS="$num_vms_arg"
	echo "Requesting $NUM_VMS VM(s) with prefix: $VM_PREFIX"
	echo ""
}

# Check if VM already exists
vm_exists() {
	local vm_name="$1"
	kubectl get vm "$vm_name" -n "$NAMESPACE" &> /dev/null
}

# Get VM status
get_vm_status() {
	local vm_name="$1"
	kubectl get vm "$vm_name" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown"
}

# Create a single VM
create_vm() {
	local vm_name="$1"
	local vm_index="$2"

	echo "[$vm_index/$NUM_VMS] Creating VM: $vm_name"

	# Check if VM already exists
	if vm_exists "$vm_name"; then
		local status
		status=$(get_vm_status "$vm_name")
		echo "  VM $vm_name already exists (status: $status)"
		if [ "$status" = "Running" ]; then
			echo "  ✓ VM is already running, skipping creation"
			return 0
		elif [ "$status" = "Stopped" ]; then
			echo "  Starting existing VM..."
			if kubectl patch vm "$vm_name" -n "$NAMESPACE" --type merge -p '{"spec":{"runStrategy":"Always"}}' &> /dev/null; then
				echo "  ✓ VM started"
				return 0
			else
				echo "  ✗ Failed to start VM"
				return 1
			fi
		else
			echo "  ℹ VM exists, will continue with existing VM"
			return 0
		fi
	fi

	# Generate SSH keys YAML
	local ssh_keys_yaml=""
	for key in "${SSH_KEYS[@]}"; do
		ssh_keys_yaml="${ssh_keys_yaml}                - ${key}\n"
	done

	# Create the VM
	if cat <<- EOF | kubectl apply -f - &> /dev/null
	apiVersion: kubevirt.io/v1
	kind: VirtualMachine
	metadata:
	  name: ${vm_name}
	  namespace: ${NAMESPACE}
	spec:
	  runStrategy: Always
	  template:
	    metadata:
	      labels:
	        kubevirt.io/size: small
	        kubevirt.io/domain: ${vm_name}
	    spec:
	      domain:
	        cpu:
	          cores: 1
	          sockets: 1
	          threads: 1
	        devices:
	          autoattachVSOCK: true
	          disks:
	            - name: containerdisk
	              bootOrder: 1
	              disk:
	                bus: virtio
	            - name: cloudinitdisk
	              bootOrder: 2
	              disk:
	                bus: virtio
	          interfaces:
	          - name: default
	            masquerade: {}
	        memory:
	          guest: 2Gi
	        resources:
	          requests:
	            memory: 2Gi
	            cpu: 100m
	      networks:
	      - name: default
	        pod: {}
	      volumes:
	        - name: containerdisk
	          containerDisk:
	            image: ${CONTAINER_IMAGE}
	        - name: cloudinitdisk
	          cloudInitNoCloud:
	            userData: |
	              #cloud-config
	              user: ${SSH_USER}
	              password: ${VM_PASSWORD}
	              chpasswd: { expire: False }
	              ssh_pwauth: True
	              ssh_authorized_keys:
	$(echo -e "$ssh_keys_yaml")
	EOF
	then
		echo "  ✓ VM $vm_name created successfully"
		return 0
	else
		echo "  ✗ Failed to create VM $vm_name"
		return 1
	fi
}

# Deploy all VMs
deploy_vms() {
	echo "=== Deploying VMs ==="
	echo ""

	local created=0
	local failed=0
	local existed=0

	for i in $(seq 1 "$NUM_VMS"); do
		local vm_name="${VM_PREFIX}-${i}"
		
		if vm_exists "$vm_name"; then
			existed=$((existed + 1))
		fi

		if create_vm "$vm_name" "$i"; then
			created=$((created + 1))
		else
			failed=$((failed + 1))
		fi
		echo ""
	done

	echo "Deployment Summary:"
	echo "  Total requested: $NUM_VMS"
	echo "  Successfully created/started: $created"
	echo "  Already existed: $existed"
	echo "  Failed: $failed"
	echo ""

	if [ $failed -gt 0 ]; then
		echo "WARNING: Some VMs failed to deploy"
	fi
}

# Wait for SSH to be available on a VM
wait_for_ssh() {
	local vm_name="$1"
	local max_retries=30
	local retry_count=0

	echo "  Waiting for SSH to be available on $vm_name..."
	
	while [ $retry_count -lt $max_retries ]; do
		if virtctl ssh \
			--namespace "$NAMESPACE" \
			--local-ssh-opts="-o StrictHostKeyChecking=no" \
			--local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
			--local-ssh-opts="-o ConnectTimeout=5" \
			--command "echo SSH ready" \
			"${SSH_USER}@vmi/${vm_name}" 2> /dev/null | grep -q "SSH ready"; then
			echo "  ✓ SSH is ready on $vm_name"
			return 0
		fi
		retry_count=$((retry_count + 1))
		if [ $((retry_count % 5)) -eq 0 ]; then
			echo "    Still waiting... ($retry_count/$max_retries attempts)"
		fi
		sleep 10
	done

	echo "  ✗ SSH did not become available on $vm_name in time"
	return 1
}

# Setup a single VM (runs in background)
setup_single_vm() {
	local vm_name="$1"
	local vm_index="$2"
	
	echo "[$vm_index/$NUM_VMS] Setting up VM: $vm_name"

	# Wait for VMI to be ready
	echo "  Waiting for VMI $vm_name to be ready..."
	if ! kubectl wait --for=condition=Ready "vmi/$vm_name" -n "$NAMESPACE" --timeout=300s 2>&1 | grep -v "condition met" > /dev/null; then
		echo "  ✗ VMI $vm_name did not become ready in time"
		return 1
	fi
	echo "  ✓ VMI is ready"

	# Wait for SSH
	if ! wait_for_ssh "$vm_name"; then
		return 1
	fi

	# Run setup script if it exists
	if [ -f "$SCRIPT_DIR/setup-vm.sh" ]; then
		echo "  Running setup-vm.sh for $vm_name..."
		if "$SCRIPT_DIR/setup-vm.sh" "$vm_name" 2>&1 | sed 's/^/    /'; then
			echo "  ✓ Setup completed for $vm_name"
			return 0
		else
			echo "  ✗ Setup failed for $vm_name"
			return 1
		fi
	else
		echo "  ℹ No setup-vm.sh found, skipping configuration"
		return 0
	fi
}

# Setup all VMs in parallel
setup_vms() {
	echo "=== Setting Up VMs ==="
	echo ""
	echo "Waiting for VMs to be ready before running setup..."
	sleep 10
	echo ""

	# Track PIDs and results
	declare -A pids
	declare -A results

	# Launch setup for each VM in parallel
	for i in $(seq 1 "$NUM_VMS"); do
		local vm_name="${VM_PREFIX}-${i}"
		setup_single_vm "$vm_name" "$i" &
		pids[$vm_name]=$!
	done

	# Wait for all background jobs and collect results
	local success=0
	local failed=0
	
	for vm_name in "${!pids[@]}"; do
		if wait "${pids[$vm_name]}"; then
			results[$vm_name]="success"
			success=$((success + 1))
		else
			results[$vm_name]="failed"
			failed=$((failed + 1))
		fi
	done

	echo ""
	echo "Setup Summary:"
	echo "  Total VMs: $NUM_VMS"
	echo "  Successfully configured: $success"
	echo "  Failed: $failed"
	echo ""

	# List failed VMs if any
	if [ $failed -gt 0 ]; then
		echo "Failed VMs:"
		for vm_name in "${!results[@]}"; do
			if [ "${results[$vm_name]}" = "failed" ]; then
				echo "  - $vm_name"
			fi
		done
		echo ""
	fi
}

# Main execution flow
main() {
	echo "=== RHEL9 VM Deployment and Configuration Script ==="
	echo ""

	parse_arguments "$@"
	check_prerequisites
	deploy_vms
	setup_vms

	echo "=== All Operations Complete ==="
	echo ""
	echo "VM login credentials:"
	echo "  Username: ${SSH_USER}"
	echo "  Password: ${VM_PASSWORD}"
	echo ""
	echo "To check VM status:"
	echo "  kubectl get vm,vmi -n $NAMESPACE"
	echo ""
	echo "To access a VM via SSH:"
	echo "  virtctl ssh -n $NAMESPACE ${SSH_USER}@vmi/${VM_PREFIX}-1"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
