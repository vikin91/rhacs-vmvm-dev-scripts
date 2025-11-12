#!/usr/bin/env bash

set -euo pipefail

# Global variables
DIR=$(cd "$(dirname "$0")" && pwd -P)
STACKROX_REPO="${STACKROX_REPO:-${HOME}/src/go/src/github.com/stackrox/stackrox}"
AGENT_DIR="${STACKROX_REPO}/compliance/virtualmachines/roxagent"
NAMESPACE="${NAMESPACE:-openshift-cnv}"
SSH_USER="${SSH_USER:-cloud-user}"
VM_PASSWORD="${VM_PASSWORD:-password}"
VMI_NAME=""
declare -a SSH_OPTS

# Check all prerequisites before proceeding
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

	if ! command -v go &> /dev/null; then
		echo "ERROR: go is not installed or not in PATH"
		exit 1
	fi

	if ! command -v git &> /dev/null; then
		echo "ERROR: git is not installed or not in PATH"
		exit 1
	fi

	if ! kubectl cluster-info &> /dev/null; then
		echo "ERROR: Cannot connect to Kubernetes cluster"
		exit 1
	fi

	if ! test -d "${STACKROX_REPO}"; then
		echo "ERROR: StackRox repository not found at: ${STACKROX_REPO}"
		echo "Please specify the location via STACKROX_REPO environment variable"
		exit 1
	fi

	if ! test -d "${AGENT_DIR}"; then
		echo "ERROR: Agent directory not found at: ${AGENT_DIR}"
		exit 1
	fi

	if ! test -f "${DIR}/vm-agent.service"; then
		echo "ERROR: vm-agent.service file not found at: ${DIR}/vm-agent.service"
		echo "Please create this file before running the script"
		exit 1
	fi

	echo "Prerequisites OK"
	echo ""
	
	# Check SSH agent
	check_ssh_agent
}

# Check if SSH agent is running and has keys loaded
check_ssh_agent() {
	echo "Checking SSH agent..."
	
	# Check if ssh-agent is running
	if [ -z "${SSH_AUTH_SOCK:-}" ]; then
		echo "⚠️  WARNING: SSH agent is not running"
		echo "   You will likely be prompted for your SSH key passphrase multiple times"
		echo ""
		echo "   To avoid this, start ssh-agent and add your key:"
		echo "   eval \$(ssh-agent)"
		echo "   ssh-add ~/.ssh/id_ed25519"
		echo ""
		return 0
	fi
	
	# Check if any keys are loaded
	local key_count
	key_count=$(ssh-add -l 2>/dev/null | grep -c "^[0-9]" || echo "0")
	
	if [ "$key_count" -eq 0 ]; then
		echo "⚠️  WARNING: No SSH keys loaded in ssh-agent"
		echo "   You will be prompted for your SSH key passphrase multiple times"
		echo ""
		echo "   To fix this, add your SSH key:"
		echo "   ssh-add ~/.ssh/id_ed25519"
		echo ""
		
		read -p "Do you want to continue anyway? (y/N): " -n 1 -r
		echo ""
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			echo "Aborted by user"
			exit 1
		fi
		echo ""
	else
		echo "✓ SSH agent is running with $key_count key(s) loaded"
		echo ""
	fi
}

# Get and set VMI name from argument or auto-detect
get_vmi_name() {
	local vmi_arg="${1:-}"
	
	if [ -n "$vmi_arg" ]; then
		VMI_NAME="$vmi_arg"
	else
		echo "No VMI name provided, searching for available VMIs..."
		VMI_NAME=$(kubectl -n "$NAMESPACE" get vmi -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
		if [ -z "$VMI_NAME" ]; then
			echo "ERROR: No VMI found in namespace $NAMESPACE"
			echo "Usage: $0 <vmi-name>"
			exit 1
		fi
		echo "Found VMI: $VMI_NAME"
	fi

	echo "Setting up VMI: ${VMI_NAME} in namespace: ${NAMESPACE}"
	echo ""
}

# Validate that VMI exists and is running
validate_vmi() {
	if ! kubectl -n "$NAMESPACE" get vmi "$VMI_NAME" &> /dev/null; then
		echo "ERROR: VMI '${VMI_NAME}' not found in namespace '${NAMESPACE}'"
		exit 1
	fi

	local vmi_phase
	vmi_phase=$(kubectl -n "$NAMESPACE" get vmi "$VMI_NAME" -o jsonpath='{.status.phase}')
	if [ "$vmi_phase" != "Running" ]; then
		echo "ERROR: VMI '${VMI_NAME}' is not running (current phase: ${vmi_phase})"
		exit 1
	fi

	echo "VMI is running"
	echo ""
}

# Setup SSH options for virtctl commands
setup_ssh_opts() {
	SSH_OPTS=(
		--namespace "$NAMESPACE"
		--local-ssh-opts="-o StrictHostKeyChecking=no"
		--local-ssh-opts="-o UserKnownHostsFile=/dev/null"
		--local-ssh-opts="-o BatchMode=yes"
		--local-ssh-opts="-o ConnectTimeout=10"
	)

	# Clean SSH known hosts
	echo "Cleaning SSH known hosts for VMI..."
	ssh-keygen -R "vmi.${VMI_NAME}.${NAMESPACE}" 2> /dev/null || true
	echo ""
}

# Test SSH connection to ensure keys are loaded
test_ssh_connection() {
	echo "Testing SSH connection to VMI..."
	
	# Try a simple SSH command
	if virtctl ssh "${SSH_OPTS[@]}" \
		--command "echo SSH_TEST_OK" \
		"${SSH_USER}@vmi/${VMI_NAME}" 2>&1 | grep -q "SSH_TEST_OK"; then
		echo "✓ SSH connection successful"
		echo ""
		return 0
	fi

	# If we got here, SSH failed
	echo "✗ SSH connection failed"
	echo ""
	echo "⚠️  This is likely because:"
	echo "   1. Your SSH key has a passphrase and is not loaded in ssh-agent"
	echo "   2. Your SSH key is not authorized on the VM"
	echo ""
	echo "To fix this, run:"
	echo "   ssh-add ~/.ssh/id_ed25519"
	echo ""
	echo "Or if you want to use password authentication, the password is:"
	echo "   ${VM_PASSWORD:-password}"
	echo ""
	
	read -p "Do you want to continue anyway? (y/N): " -n 1 -r
	echo ""
	if [[ ! $REPLY =~ ^[Yy]$ ]]; then
		echo "Aborted by user"
		exit 1
	fi
	echo "Continuing... (you may be prompted for passwords)"
	echo ""
}

# Check git repository branch and warn if not on master
check_git_branch() {
	echo "Checking git repository status..."
	cd "${STACKROX_REPO}"

	# Check if it's a git repository
	if ! git rev-parse --git-dir &> /dev/null; then
		echo "WARNING: ${STACKROX_REPO} is not a git repository"
		echo ""
		return 0
	fi

	# Get current branch
	local current_branch
	current_branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD)
	echo "Current branch: $current_branch"

	# Check for uncommitted changes
	if ! git diff-index --quiet HEAD -- 2>/dev/null; then
		echo "WARNING: Repository has uncommitted changes"
		echo "The built binary will include these local modifications"
		echo ""
	fi

	# Show the commit that will be built
	local commit_info
	commit_info=$(git log -1 --oneline 2>/dev/null || echo "unknown")
	echo "Building from commit: $commit_info"
	echo ""

	# Warn if not on master branch
	if [ "$current_branch" != "master" ] && [ "$current_branch" != "main" ]; then
		echo "⚠️  WARNING: You are not on the master/main branch!"
		echo "   Current branch: $current_branch"
		echo ""
		read -p "Do you want to continue? (y/N): " -n 1 -r
		echo ""
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			echo "Aborted by user"
			exit 1
		fi
		echo ""
	fi
}

# Check if service is already installed and stop it if running
check_existing_service() {
	echo "Checking if vm-agent service is already installed..."
	
	local service_status
	service_status=$(virtctl ssh "${SSH_OPTS[@]}" \
		--command "sudo systemctl is-active vm-agent.service 2>/dev/null || echo 'not-found'" \
		"${SSH_USER}@vmi/${VMI_NAME}" 2>/dev/null || echo "not-found")

	if [ "$service_status" = "active" ]; then
		echo "vm-agent service is already running on VMI '${VMI_NAME}'"
		echo "Stopping service to update..."
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "sudo systemctl stop vm-agent.service" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		echo "Service stopped"
	elif [ "$service_status" = "inactive" ] || [ "$service_status" = "failed" ]; then
		echo "vm-agent service exists but is not running (status: $service_status)"
		echo "Will update and restart..."
	else
		echo "vm-agent service not found, will perform fresh installation"
	fi
	echo ""
}

# Build the VM agent binary
build_agent() {
	echo "Building VM agent binary..."
	cd "${AGENT_DIR}"
	
	if ! GOOS=linux GOARCH=amd64 go build -o "${DIR}/vm-agent-amd64" .; then
		echo "ERROR: Failed to build vm-agent binary"
		exit 1
	fi
	
	echo "Build successful: ${DIR}/vm-agent-amd64"
	echo ""
}

# Copy binary and service file to VMI
copy_files_to_vmi() {
	echo "Copying VM agent binary to VMI..."
	if ! virtctl scp "${SSH_OPTS[@]}" \
		"${DIR}/vm-agent-amd64" \
		"${SSH_USER}@vmi/${VMI_NAME}:"; then
		echo "ERROR: Failed to copy agent binary"
		exit 1
	fi
	echo "Binary copied successfully"
	echo ""

	echo "Copying systemd service file to VMI..."
	if ! virtctl scp "${SSH_OPTS[@]}" \
		"${DIR}/vm-agent.service" \
		"${SSH_USER}@vmi/${VMI_NAME}:"; then
		echo "ERROR: Failed to copy service file"
		exit 1
	fi
	echo "Service file copied successfully"
	echo ""
}

# Install and start the systemd service
install_and_start_service() {
	echo "Installing and starting vm-agent service..."
	
	local install_cmd
	install_cmd="sudo mv ~/vm-agent.service /etc/systemd/system/ && \
sudo restorecon -v /etc/systemd/system/vm-agent.service 2>/dev/null || true && \
sudo chmod +x ~/vm-agent-amd64 && \
sudo chcon -t bin_t ~/vm-agent-amd64 2>/dev/null || true && \
sudo systemctl daemon-reload && \
sudo systemctl enable vm-agent.service && \
sudo systemctl start vm-agent.service"

	if ! virtctl ssh "${SSH_OPTS[@]}" \
		--command "$install_cmd" \
		"${SSH_USER}@vmi/${VMI_NAME}"; then
		echo "ERROR: Failed to install and start service"
		exit 1
	fi
	
	echo "Service installed and started"
	echo ""
}

# Verify that the service is running correctly
verify_service() {
	echo "Verifying service status..."
	sleep 2  # Give service a moment to start
	
	local service_result
	service_result=$(virtctl ssh "${SSH_OPTS[@]}" \
		--command "sudo systemctl status vm-agent.service --no-pager" \
		"${SSH_USER}@vmi/${VMI_NAME}" 2>&1 || true)

	echo "$service_result"
	echo ""

	if echo "$service_result" | grep -q "Active: active (running)"; then
		echo "=== Installation Complete ==="
		echo "vm-agent service is successfully running on VMI '${VMI_NAME}'"
		return 0
	else
		echo "WARNING: Service may not be running correctly"
		echo "Check the status above for details"
		return 1
	fi
}

# Main execution flow
main() {
	echo "=== VMI Agent Setup Script ==="
	echo ""

	check_prerequisites
	get_vmi_name "${1:-}"
	validate_vmi
	setup_ssh_opts
	test_ssh_connection
	check_git_branch
	check_existing_service
	build_agent
	copy_files_to_vmi
	install_and_start_service
	verify_service
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
