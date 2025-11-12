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

**⚠️ Must change:**
- **SSH keys** - Replace with your team's public SSH keys in the `SSH_KEYS` array

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

## Quick Start Workflow

```bash
# 0. Create an Openshift cluster

# 1. Set your kubeconfig to point to the Openshift cluster
export KUBECONFIG=~/.kube/config

# 2. Install OpenShift Virtualization
./virt.sh

# 3. Deploy 3 VMs with custom prefix
VM_PREFIX=myvm ./add-vms.sh 3

# 4. VMs are now running with vm-agent installed
kubectl get vm,vmi -n openshift-cnv

# 5. View logs from a VM
./vm-logs.sh myvm-1 follow

# 6. Access a VM
virtctl ssh -n openshift-cnv cloud-user@vmi/myvm-1
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

# SSH into VM manually
virtctl ssh -n openshift-cnv cloud-user@vmi/<vm-name>
```

