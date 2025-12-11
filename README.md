# VM Deployment and Management Scripts

Automated setup for OpenShift Virtualization and RHEL9 VMs with vm-agent service.

ACS can be deployed before or after executing actions from those scripts (or not at all, but the roxagent will not work).

## Prerequisites

### Environment
- **KUBECONFIG** - Must be set (not a script parameter) and point to valid OpenShift cluster
- **kubectl** and **virtctl** - Required for all scripts
- **go** and **git** - Required for `setup-vm.sh` only

### Repository
- `setup-vm.sh` requires: `STACKROX_REPO` environment variable pointing to stackrox/stackrox repository (default: `~/src/go/src/github.com/stackrox/stackrox`)

### SSH Key Setup (Required Before First Use)

You **must** add your SSH public key to `add-vms.sh` before deploying VMs. This key is injected via cloud-init and allows you to SSH into the VMs.

**Location:** Edit the `SSH_KEYS` array in `add-vms.sh` (around line 20):

```bash
# SSH keys for cloud-init
SSH_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your-email@example.com"
    "ssh-rsa AAAAB3NzaC1yc2EAAAA... another-user@example.com"
)
```

**How to get your SSH public key:**
```bash
# If you have an existing key:
cat ~/.ssh/id_ed25519.pub   # or id_rsa.pub

# If you need to generate one:
ssh-keygen -t ed25519 -C "your-email@example.com"
cat ~/.ssh/id_ed25519.pub
```

Copy the entire output line (starting with `ssh-ed25519` or `ssh-rsa`) and add it to the `SSH_KEYS` array. Multiple keys can be added for team access.

## Scripts Overview

### 1. virt.sh - Install OpenShift Virtualization

**What it needs:**
- KUBECONFIG set
- OpenShift cluster with redhat-operators catalog

**Inputs:**
- None (no arguments or parameters)

**What it does:**
1. Creates `openshift-cnv` namespace
2. Installs OpenShift Virtualization operator via OLM
3. Enables VSOCK feature gate
4. Enables KVM_EMULATION
5. Waits for HyperConverged to be healthy (up to 30 minutes)

**Hardcoded values:**
- Namespace: `openshift-cnv`
- Operator: `kubevirt-hyperconverged` from `redhat-operators`

**After completion:**
- OpenShift Virtualization is installed and ready
- VSOCK may need manual console activation (see script comments if relay fails)
- Run `add-vms.sh` to deploy VMs

---

### 2. add-vms.sh - Deploy RHEL9 VMs

**What it needs:**
- KUBECONFIG set
- Target namespace must exist (default: `openshift-cnv`)
- Optional: `setup-vm.sh` in same directory for VM configuration

**Inputs:**
- **Argument**: Number of VMs (default: 1)
- **Environment Variables**:
  - `NAMESPACE` - Target namespace (default: `openshift-cnv`)
  - `VM_PREFIX` - VM name prefix (default: `rhel9`, creates `rhel9-1`, `rhel9-2`, etc.)
  - `SSH_USER` - VM username (default: `cloud-user`)
  - `VM_PASSWORD` - User password (default: `password`)
  - `CONTAINER_IMAGE` - Base image (default: `registry.redhat.io/rhel9/rhel-guest-image:latest`)

**What it does:**
1. Creates N VirtualMachine resources with cloud-init
2. Waits for VMs to be ready and SSH-accessible
3. Runs `setup-vm.sh` on each VM in parallel (if present)
4. Reports deployment summary

**⚠️ Must change before first use:**
- **SSH keys** - Add your public SSH key(s) to the `SSH_KEYS` array (see [SSH Key Setup](#ssh-key-setup-required-before-first-use) above)

**Hardcoded values to customize:**
- CPU: 1 core
- Memory: 2Gi
- VSOCK: enabled

**After completion:**
- VMs are running and SSH-accessible
- Default credentials: `cloud-user` / `password`
- Access: `virtctl ssh -n openshift-cnv cloud-user@vmi/rhel9-1`
- Check: `kubectl get vm,vmi -n openshift-cnv`

---

### 3. setup-vm.sh - Install VM Agent Service

**What it needs:**
- KUBECONFIG set
- STACKROX_REPO environment variable or default path must exist
- `vm-agent.service` file in same directory
- SSH key loaded in ssh-agent (or will prompt repeatedly)

**Inputs:**
- **Argument**: VMI name (auto-detects first VMI if omitted)
- **Environment Variables**:
  - `NAMESPACE` - Target namespace (default: `openshift-cnv`)
  - `SSH_USER` - VM username (default: `cloud-user`)
  - `VM_PASSWORD` - User password (default: `password`)
  - `STACKROX_REPO` - Path to stackrox repo (default: `~/src/go/src/github.com/stackrox/stackrox`)

**What it does:**
1. Validates prerequisites (kubectl, virtctl, go, git)
2. Checks SSH connection to VM
3. Warns if not on master/main branch
4. Stops existing vm-agent service (if running)
5. Builds vm-agent binary for linux/amd64
6. Copies binary and service file to VM
7. Installs and starts systemd service
8. Verifies service is running

**Hardcoded values:**
- Agent source: `${STACKROX_REPO}/compliance/virtualmachines/roxagent`
- SSH options: BatchMode, StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null
- Service install path: `/etc/systemd/system/`

**After completion:**
- vm-agent service running on VM
- Check: `./vm-logs.sh <vm-name> status`
- Binary location: `~/vm-agent-amd64` on VM
- Logs: `sudo journalctl -u vm-agent.service`

---

### 4. vm-logs.sh - View VM Agent Logs

**What it needs:**
- KUBECONFIG set
- Target VMI must be running with vm-agent installed

**Inputs:**
- **Argument 1**: VMI name (required)
- **Argument 2**: Action (optional, default: `tail`)
  - `tail` or `t` - Last 50 lines
  - `follow` or `f` - Follow in real-time
  - `status` or `s` - Service status
  - `all` or `a` - All logs
- **Environment Variables**:
  - `NAMESPACE` - Target namespace (default: `openshift-cnv`)
  - `SSH_USER` - VM username (default: `cloud-user`)

**What it does:**
- Connects to VM via virtctl ssh
- Runs journalctl commands to view vm-agent service logs

**Hardcoded values:**
- Service name: `vm-agent.service`
- Default lines shown: 50

**After completion:**
- No persistent state changes
- Use for monitoring and troubleshooting

---

### 5. vm-agent-debug.sh - Enable/Disable Debug Logging

**What it needs:**
- KUBECONFIG set
- Target VMI must be running with vm-agent installed

**Inputs:**
- **Argument 1**: VMI name (required)
- **Argument 2**: Action (optional, default: `status`)
  - `enable` or `e` - Enable debug logging (adds `--log-level debug`)
  - `disable` or `d` - Disable debug logging
  - `status` or `s` - Show current service configuration
  - `flags` or `f` - Show all available agent flags
- **Environment Variables**:
  - `NAMESPACE` - Target namespace (default: `openshift-cnv`)
  - `SSH_USER` - VM username (default: `cloud-user`)

**What it does:**
- Modifies the systemd service file to enable/disable debug flags
- Restarts the vm-agent service automatically

**After completion:**
- Agent runs with modified logging level
- View debug logs with: `./vm-logs.sh <vm-name> follow`

## Quick Start Workflow

Follow these steps to get VMs running with the vm-agent deployed:

```bash
# 0. Prerequisites: Have an OpenShift cluster ready

# 1. Set your kubeconfig to point to the OpenShift cluster
export KUBECONFIG=~/.kube/config

# 2. Add your SSH public key to add-vms.sh (REQUIRED - see "SSH Key Setup" above)
#    Edit the SSH_KEYS array in add-vms.sh with your key from:
cat ~/.ssh/id_ed25519.pub

# 3. Set the path to your stackrox repository (for building the agent)
export STACKROX_REPO=~/path/to/stackrox/stackrox

# 4. Install OpenShift Virtualization (takes ~10-30 minutes)
./virt.sh

# 5. Deploy VMs (this also runs setup-vm.sh automatically to install the agent)
./add-vms.sh 3    # Deploy 3 VMs named rhel9-1, rhel9-2, rhel9-3

# 6. Verify VMs are running with agent installed
kubectl get vm,vmi -n openshift-cnv
./vm-logs.sh rhel9-1 status

# 7. View agent logs
./vm-logs.sh rhel9-1 follow

# 8. (Optional) SSH into a VM
virtctl ssh -n openshift-cnv cloud-user@vmi/rhel9-1
```

### Manual Agent Installation

If you need to install/update the agent on a VM manually (e.g., after code changes):

```bash
# Install agent on a specific VM
./setup-vm.sh rhel9-1

# Or let it auto-detect the first available VM
./setup-vm.sh
```

## Common Environment Variables

Set these before running scripts to customize behavior:

```bash
export KUBECONFIG=~/.kube/config                    # Required for all
export NAMESPACE=my-vms                              # Custom namespace
export VM_PREFIX=test                                # Custom VM names
export STACKROX_REPO=~/code/stackrox                # Custom repo path
export SSH_USER=cloud-user                           # VM username
export VM_PASSWORD=mypassword                        # VM password
```

## Troubleshooting

```bash
# Check cluster connection
kubectl cluster-info

# Check namespace exists
kubectl get namespace openshift-cnv

# Check VM status
kubectl get vm,vmi -n openshift-cnv

# View VM console
virtctl console <vm-name> -n openshift-cnv

# Check vm-agent service
./vm-logs.sh <vm-name> status

# Enable debug logging for more detailed output
./vm-agent-debug.sh <vm-name> enable
./vm-logs.sh <vm-name> follow

# SSH into VM manually
virtctl ssh -n openshift-cnv cloud-user@vmi/<vm-name>

# Sync time on VM (if time drift issues)
virtctl ssh -n openshift-cnv cloud-user@vmi/<vm-name> \
  --command "sudo timedatectl set-ntp true && sudo chronyc makestep"
```

