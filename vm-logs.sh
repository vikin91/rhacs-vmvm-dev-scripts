#!/usr/bin/env bash

# Helper script to view VM agent logs
# Usage: ./vm-logs.sh <vmi-name> [follow|status]

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-cnv}"
SSH_USER="${SSH_USER:-cloud-user}"
VMI_NAME="${1:-}"
ACTION="${2:-tail}"

# Function to list available VMs
list_vms() {
	echo "Available VMs in namespace $NAMESPACE:"
	kubectl get vmi -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none found or unable to connect to cluster)"
}

# Show usage
show_usage() {
	echo "Usage: $0 <vmi-name> [follow|status|tail|all|flags]"
	echo ""
	echo "Examples:"
	echo "  $0 rhel9-1              # Show last 50 lines"
	echo "  $0 rhel9-1 follow       # Follow logs in real-time"
	echo "  $0 rhel9-1 status       # Show service status"
	echo "  $0 rhel9-1 all          # Show all logs"
	echo "  $0 rhel9-1 flags        # Show available agent flags"
	echo ""
	list_vms
}

if [ -z "$VMI_NAME" ]; then
	show_usage
	exit 1
fi

# Catch common mistake: using action keyword as VM name
case "$VMI_NAME" in
	follow|f|status|s|tail|t|all|a)
		echo "ERROR: '$VMI_NAME' looks like an action, not a VM name!"
		echo ""
		show_usage
		exit 1
		;;
esac

# Validate that the VM exists
if ! kubectl get vmi "$VMI_NAME" -n "$NAMESPACE" &>/dev/null; then
	echo "ERROR: Virtual machine instance '$VMI_NAME' not found in namespace '$NAMESPACE'"
	echo ""
	list_vms
	exit 1
fi

SSH_OPTS=(
	--namespace "$NAMESPACE"
	--local-ssh-opts="-o StrictHostKeyChecking=no"
	--local-ssh-opts="-o UserKnownHostsFile=/dev/null"
)

case "$ACTION" in
	follow|f)
		echo "Following logs for vm-agent on $VMI_NAME (Ctrl+C to stop)..."
		echo ""
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "sudo journalctl -u vm-agent.service -f --no-pager" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		;;
	status|s)
		echo "Service status for vm-agent on $VMI_NAME:"
		echo ""
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "sudo systemctl status vm-agent.service --no-pager" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		;;
	all|a)
		echo "All logs for vm-agent on $VMI_NAME:"
		echo ""
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "sudo journalctl -u vm-agent.service --no-pager" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		;;
	tail|t|*)
		echo "Last 50 lines of logs for vm-agent on $VMI_NAME:"
		echo ""
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "sudo journalctl -u vm-agent.service -n 50 --no-pager" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		;;
	help-flags|flags)
		echo "Checking available vm-agent command-line flags:"
		echo ""
		virtctl ssh "${SSH_OPTS[@]}" \
			--command "~/vm-agent-amd64 --help 2>&1 || ~/vm-agent-amd64 -h 2>&1 || echo 'No help output available'" \
			"${SSH_USER}@vmi/${VMI_NAME}"
		;;
esac

