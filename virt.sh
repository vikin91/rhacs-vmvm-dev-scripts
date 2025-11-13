#!/usr/bin/env bash

set -euo pipefail

DIR=$(cd $(dirname $0) && pwd -P)

function virtInstall() {
	# Install openshift virtualization operator in cluster
	OLM_NAMESPACE="openshift-cnv"
	SUBSCRIPTION_NAME="kubevirt-hyperconverged"
	HCO_NAMESPACE="$OLM_NAMESPACE"
	HCO_NAME="kubevirt-hyperconverged"

	echo "=== OpenShift Virtualization Installer ==="
	echo ""

	# Check prerequisites
	echo "Checking prerequisites..."
	if ! command -v kubectl &> /dev/null; then
		echo "ERROR: kubectl is not installed or not in PATH"
		exit 1
	fi

	if ! kubectl cluster-info &> /dev/null; then
		echo "ERROR: Cannot connect to Kubernetes cluster"
		echo "Make sure your kubeconfig is set correctly and cluster is accessible"
		exit 1
	fi

	if ! kubectl get catalogsource redhat-operators -n openshift-marketplace &> /dev/null; then
		echo "WARNING: redhat-operators catalog source not found in openshift-marketplace"
		echo "This is required for OpenShift Virtualization installation"
	fi

	echo "Prerequisites OK"
	echo ""

	# Check if already installed and healthy
	if kubectl get hyperconverged "$HCO_NAME" -n "$HCO_NAMESPACE" &> /dev/null; then
		echo "HyperConverged CR already exists, checking status..."
		avail=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2> /dev/null || echo "Unknown")
		prog=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2> /dev/null || echo "Unknown")
		degr=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2> /dev/null || echo "Unknown")
		
		if [ "$avail" = "True" ] && [ "$prog" = "False" ] && [ "$degr" = "False" ]; then
			echo "OpenShift Virtualization is already installed and healthy"
			echo "Ensuring VSOCK feature gate and KVM_EMULATION are configured..."
			# Continue to apply configuration updates
		else
			echo "OpenShift Virtualization exists but not healthy (Available=$avail, Progressing=$prog, Degraded=$degr)"
			echo "Continuing with installation/update..."
		fi
		echo ""
	fi

	echo "Installing OpenShift Virtualization (HCO) via OLM in namespace: $OLM_NAMESPACE"

	cat <<- 'EOF' | kubectl apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: openshift-cnv
	---
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: openshift-cnv
	  namespace: openshift-cnv
	spec:
	  targetNamespaces:
	  - openshift-cnv
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: kubevirt-hyperconverged
	  namespace: openshift-cnv
	spec:
	  channel: stable
	  name: kubevirt-hyperconverged
	  source: redhat-operators
	  sourceNamespace: openshift-marketplace
	  installPlanApproval: Automatic
	EOF

	echo "Applied namespace, operator group, and subscription"
	echo ""

	# Check if CSV is already present
	if kubectl -n "$OLM_NAMESPACE" get sub "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}' 2> /dev/null | grep -q .; then
		CSV=$(kubectl -n "$OLM_NAMESPACE" get sub "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}')
		PHASE=$(kubectl -n "$OLM_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}' 2> /dev/null || echo "Unknown")
		if [ "$PHASE" = "Succeeded" ]; then
			echo "Operator already installed: $CSV (Phase: $PHASE)"
		else
			echo "Operator installation in progress: $CSV (Phase: $PHASE)"
		fi
	else
		echo "Waiting for Subscription to report installedCSV..."
	fi

	# Wait for installedCSV
	timeout=300
	elapsed=0
	until kubectl -n "$OLM_NAMESPACE" get sub "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}' 2> /dev/null | grep -q .; do
		sleep 5
		elapsed=$((elapsed + 5))
		if [ $elapsed -ge $timeout ]; then
			echo "ERROR: Timeout waiting for Subscription to report installedCSV after ${timeout}s"
			exit 1
		fi
		if [ $((elapsed % 30)) -eq 0 ]; then
			echo "Still waiting for installedCSV... (${elapsed}s elapsed)"
		fi
	done
	
	CSV=$(kubectl -n "$OLM_NAMESPACE" get sub "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}')
	echo "InstalledCSV: $CSV"

	echo "Waiting for CSV to reach Succeeded phase..."
	for i in $(seq 1 180); do
		PHASE=$(kubectl -n "$OLM_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}' 2> /dev/null || true)
		if [ "$PHASE" = "Succeeded" ]; then
			echo "CSV is Succeeded"
			break
		fi
		# Warn only on truly problematic phases
		if [ -n "$PHASE" ] && [ "$PHASE" != "Installing" ] && [ "$PHASE" != "Pending" ] && [ "$PHASE" != "InstallReady" ]; then
			echo "WARNING: Unexpected CSV phase: $PHASE"
		fi
		if [ $((i % 12)) -eq 0 ]; then
			echo "Still waiting for CSV (Phase: ${PHASE:-Unknown}, ${i}0s elapsed)..."
		fi
		sleep 5
	done
	
	# Verify CSV reached Succeeded
	FINAL_PHASE=$(kubectl -n "$OLM_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')
	if [ "$FINAL_PHASE" != "Succeeded" ]; then
		echo "ERROR: CSV did not reach Succeeded phase (current: $FINAL_PHASE)"
		exit 1
	fi
	echo ""

	echo "Creating/Updating HyperConverged CR with VSOCK feature gate..."
	cat <<- EOF | kubectl apply -f -
	apiVersion: hco.kubevirt.io/v1beta1
	kind: HyperConverged
	metadata:
	  name: ${HCO_NAME}
	  namespace: ${HCO_NAMESPACE}
	  annotations:
	    kubevirt.kubevirt.io/jsonpatch: |-
	      [
	        {
	          "op":"add",
	          "path":"/spec/configuration/developerConfiguration/featureGates/-",
	          "value":"VSOCK"
	        }
	      ]
	spec: {}
	EOF

	echo "Applied HyperConverged CR with VSOCK feature gate"
	echo ""

	# VSOCK feature gate was enabled, but sometimes this requires manual clicking to actually take effect.
	# If you see this error in the relay logs:
	#
	#   Error running virtual machine relay: starting vsock server: listening on port 818: listen vsock host(2):818: bind: cannot assign requested address
	#
	# Then manual action is needed:
	# - Open the Openshift console
	# - Navigate to "Installed operators" -> "OpenShift Virtualization" -> "OpenShift Virtualization Deployment"/"HyperConvergeds"
	#     -> click on "kubevirt-hyperconverged" (there should be only one) -> YAML -> Add this under metadata -> annotations and click "save":
	#
	#       kubevirt.kubevirt.io/jsonpatch: |-
	#       [
	#         {
	#           "op":"add",
	#           "path":"/spec/configuration/developerConfiguration/featureGates/-",
	#           "value":"VSOCK"
	#         }
	#       ]
	#
	# - Note: that annotation was likely already there, you still need to click "save" for the setting to actually get enabled
	# - Restart your collector daemonset if needed

	echo "Waiting for HyperConverged to become healthy (Available=True, Progressing=False, Degraded=False)..."
	max_wait=1800  # 30 minutes
	elapsed=0
	while :; do
		avail=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2> /dev/null || echo "Unknown")
		prog=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2> /dev/null || echo "Unknown")
		degr=$(kubectl -n "$HCO_NAMESPACE" get hyperconverged "$HCO_NAME" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2> /dev/null || echo "Unknown")

		if [ "$avail" = "True" ] && [ "$prog" = "False" ] && [ "$degr" = "False" ]; then
			echo "HyperConverged is healthy"
			break
		fi

		if [ $elapsed -ge $max_wait ]; then
			echo "ERROR: Timeout waiting for HyperConverged to become healthy after ${max_wait}s"
			echo "Current status: Available=$avail, Progressing=$prog, Degraded=$degr"
			exit 1
		fi

		if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
			echo "Still waiting... (Available=$avail, Progressing=$prog, Degraded=$degr) - ${elapsed}s elapsed"
		fi

		sleep 10
		elapsed=$((elapsed + 10))
	done
	echo ""

	# Check if KVM_EMULATION is already set
	current_kvm_setting=$(kubectl get subscription kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.config.env[?(@.name=="KVM_EMULATION")].value}' 2> /dev/null || echo "")
	if [ "$current_kvm_setting" = "true" ]; then
		echo "KVM_EMULATION is already set to 'true' in subscription"
	else
		echo "Patching subscription with KVM_EMULATION setting..."
		kubectl patch subscription kubevirt-hyperconverged \
		    -n openshift-cnv \
		    --type=merge \
		    -p '{"spec":{"config":{"selector":{"matchLabels":{"name":"hyperconverged-cluster-operator"}},"env":[{"name":"KVM_EMULATION","value":"true"}]}}}'
		echo "Subscription patched successfully"
	fi

	echo ""
	echo "=== Installation Complete ==="
	echo "OpenShift Virtualization has been successfully installed and configured with:"
	echo "  - VSOCK feature gate enabled"
	echo "  - KVM_EMULATION enabled"
	echo ""
	echo "Note: If VSOCK doesn't work immediately, you may need to manually save the"
	echo "HyperConverged CR in the OpenShift console (see comments in script for details)"
}

# Execute if called directly (not sourced)
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
	virtInstall
fi
