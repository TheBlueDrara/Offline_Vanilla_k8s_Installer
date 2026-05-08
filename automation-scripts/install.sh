#!/usr/bin/env bash
# Developed by Alex Umansky aka TheBlueDrara
# Purpose: Install vanilla Kubernetes offline on Ubuntu 24.04. Detects node
#          role at runtime: control_plane initialises the cluster and writes
#          a join command; worker consumes that command and joins.
# Version: 3.0.0
set -o errexit
set -o nounset
set -o pipefail

# ── Version constants ──────────────────────────────────────────────────────
# Change these when targeting a different k8s release; they are the only
# place in the script where version information lives.
K8S_VERSION="1.30.14"
POD_NETWORK_CIDR="192.168.0.0/16"
CRI_SOCKET="unix:///run/containerd/containerd.sock"

# ── Well-known paths ───────────────────────────────────────────────────────
MANIFESTS_PATH="/etc/kubernetes/manifests"
JOIN_COMMAND_PATH="/tmp/join_command.txt"

# ── Overridable asset paths ────────────────────────────────────────────────
# Default: payload/ and configs/ are siblings of this script on disk.
# Override via environment variable when the layout differs (e.g. Ansible).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${PAYLOAD_DIR:-${SCRIPT_DIR}/payload}"
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/configs}"

# ── Runtime state (set by main → resolve_real_user) ───────────────────────
ROLE=""
CONTROL_PLANE_IP=""
REAL_USER=""
REAL_HOME=""

# ── Error tracing ──────────────────────────────────────────────────────────
trap 'echo "ERROR: command failed on line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ══════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════

# Asserts that a tier directory exists and contains at least one .deb file.
# Pre:  $1 is the absolute path to a tier directory.
# Post: exits 1 with a clear message if no .deb files are found.
function require_debs() {
    local dir="$1"
    local count
    count=$(find "${dir}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    if [[ "${count}" -eq 0 ]]; then
        echo "ERROR: No .deb files found in ${dir}" >&2
        exit 1
    fi
}

# Installs all .deb files in a tier directory via a single dpkg -i call.
# Pre:  require_debs has confirmed the directory is non-empty.
# Post: all packages in the directory are installed.
function dpkg_install_tier() {
    local dir="$1"
    local -a debs
    mapfile -t debs < <(find "${dir}" -maxdepth 1 -name '*.deb' | sort)
    dpkg -i "${debs[@]}"
}

# ══════════════════════════════════════════════════════════════════════════
# SETUP AND VALIDATION
# ══════════════════════════════════════════════════════════════════════════

# Determines the non-root user who invoked sudo.
# Pre:  script is running as root (EUID == 0).
# Post: REAL_USER and REAL_HOME are set; falls back to "root" when there is
#       no sudo context (e.g. direct root login or a CI environment).
function resolve_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        REAL_USER="${SUDO_USER}"
    else
        REAL_USER="$(logname 2>/dev/null || echo root)"
    fi
    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
}

# Checks all preconditions before any installation work begins.
# Pre:  args have been parsed; PAYLOAD_DIR and CONFIG_DIR are set.
# Post: exits 1 if any precondition fails; returns 0 when all pass.
function validate_environment() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: Run this script as root (e.g. sudo bash install.sh ...)." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]] && \
       [[ "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
        echo "ERROR: This installer targets Ubuntu 24.04. Detected OS: ${ID}" >&2
        exit 1
    fi

    if command -v docker &>/dev/null; then
        echo "ERROR: Docker is installed. Remove it before running this installer." >&2
        exit 1
    fi

    if [[ "${ROLE}" != "control_plane" && "${ROLE}" != "worker" ]]; then
        echo "ERROR: --role must be 'control_plane' or 'worker'. Got: '${ROLE:-<unset>}'" >&2
        exit 1
    fi

    if [[ "${ROLE}" == "control_plane" && -z "${CONTROL_PLANE_IP}" ]]; then
        echo "ERROR: --master <IP> is required when --role is control_plane." >&2
        exit 1
    fi

    if [[ ! -d "${PAYLOAD_DIR}" ]]; then
        echo "ERROR: Payload directory not found: ${PAYLOAD_DIR}" >&2
        exit 1
    fi

    if [[ ! -d "${CONFIG_DIR}" ]]; then
        echo "ERROR: Config directory not found: ${CONFIG_DIR}" >&2
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# PREREQUISITES  (every node, every role)
# ══════════════════════════════════════════════════════════════════════════

# Disables swap for the current boot and comments out swap entries in /etc/fstab.
# Pre:  running as root.
# Post: no swap is active; swap entries in fstab are commented out.
function disable_swap() {
    if [[ -z "$(swapon --noheadings --show)" ]]; then
        echo "Swap already disabled."
        return 0
    fi

    echo "Disabling swap..."
    swapoff -a
    sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

    if [[ -n "$(swapon --noheadings --show)" ]]; then
        echo "ERROR: Failed to disable swap." >&2
        exit 1
    fi
}

# Installs OS-level prerequisites (conntrack, socat, ebtables, iptables)
# from payload/debs/tier-1/.
# Pre:  payload/debs/tier-1/ exists and contains .deb files.
# Post: conntrack and socat are present on the system.
function install_os_deps() {
    if dpkg -s conntrack &>/dev/null && dpkg -s socat &>/dev/null; then
        echo "OS dependencies already installed."
        return 0
    fi

    echo "Installing OS dependencies (tier-1)..."
    require_debs "${PAYLOAD_DIR}/debs/tier-1"
    dpkg_install_tier "${PAYLOAD_DIR}/debs/tier-1"
}

# Installs containerd.io from payload/debs/tier-2/, writes the runtime
# config, and verifies the service starts.
# Pre:  tier-1 OS deps installed; payload/debs/tier-2/ has .deb files;
#       configs/containerd_conf/config.toml exists.
# Post: containerd is installed, configured with SystemdCgroup=true, and active.
function install_containerd() {
    if command -v containerd &>/dev/null && systemctl is-active --quiet containerd; then
        echo "containerd already installed and active; refreshing config."
    else
        echo "Installing containerd (tier-2)..."
        require_debs "${PAYLOAD_DIR}/debs/tier-2"
        dpkg_install_tier "${PAYLOAD_DIR}/debs/tier-2"
    fi

    mkdir -p /etc/containerd
    cp "${CONFIG_DIR}/containerd_conf/config.toml" /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd

    local retries=10
    while [[ ${retries} -gt 0 ]]; do
        if systemctl is-active --quiet containerd; then
            echo "containerd is active."
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 1
    done

    echo "ERROR: containerd did not start within the expected time." >&2
    journalctl -u containerd --no-pager -n 30 >&2
    exit 1
}

# Installs the kubernetes-cni package from payload/debs/tier-3/.
# Pre:  containerd installed; payload/debs/tier-3/ has .deb files.
# Post: CNI plugin binaries are present under /opt/cni/bin/.
function install_cni() {
    if dpkg -s kubernetes-cni &>/dev/null; then
        echo "kubernetes-cni already installed."
        return 0
    fi

    echo "Installing kubernetes-cni (tier-3)..."
    require_debs "${PAYLOAD_DIR}/debs/tier-3"
    dpkg_install_tier "${PAYLOAD_DIR}/debs/tier-3"
}

# Installs cri-tools (crictl) from payload/debs/tier-4/.
# Pre:  containerd running; payload/debs/tier-4/ has .deb files.
# Post: crictl is on PATH.
function install_cri_tools() {
    if command -v crictl &>/dev/null; then
        echo "cri-tools already installed."
        return 0
    fi

    echo "Installing cri-tools (tier-4)..."
    require_debs "${PAYLOAD_DIR}/debs/tier-4"
    dpkg_install_tier "${PAYLOAD_DIR}/debs/tier-4"
}

# Installs kubelet, kubeadm, and kubectl from payload/debs/tier-5/ and
# holds them at this version to prevent accidental apt upgrades.
# Pre:  CNI and cri-tools installed; payload/debs/tier-5/ has .deb files.
# Post: kubelet, kubeadm, kubectl at K8S_VERSION are on PATH and held.
#       If a different version is already installed, exits 1 — version
#       changes are outside the scope of this installer.
function install_kube_binaries() {
    local installed_version
    installed_version="$(kubelet --version 2>/dev/null | sed 's/Kubernetes v//' || true)"

    if [[ -n "${installed_version}" ]]; then
        if [[ "${installed_version}" == "${K8S_VERSION}" ]]; then
            echo "kube binaries already at v${K8S_VERSION}."
            return 0
        fi
        echo "ERROR: Found kube binaries at v${installed_version}, expected v${K8S_VERSION}." >&2
        echo "Version changes are out of scope for this installer. Manual intervention required." >&2
        exit 1
    fi

    echo "Installing kube binaries (tier-5)..."
    require_debs "${PAYLOAD_DIR}/debs/tier-5"
    dpkg_install_tier "${PAYLOAD_DIR}/debs/tier-5"

    apt-mark hold kubelet kubeadm kubectl
    systemctl daemon-reload
    systemctl enable kubelet
}

# Loads overlay and br_netfilter kernel modules and ensures they persist
# across reboots. Applies sysctl settings required for k8s networking.
# Pre:  running as root.
# Post: both modules loaded; /etc/modules-load.d/k8s.conf written;
#       sysctl settings from network.conf applied to the running kernel.
function configure_kernel() {
    # /sys/module/<name> is present iff the module is currently loaded —
    # more reliable than parsing lsmod output.
    [[ -d /sys/module/overlay ]]      || modprobe overlay
    [[ -d /sys/module/br_netfilter ]] || modprobe br_netfilter

    printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf

    cp "${CONFIG_DIR}/iptables_conf/network.conf" /etc/sysctl.d/99-k8s-cri.conf
    sysctl --system > /dev/null
}

# Switches iptables to legacy mode when the iptables-legacy binary is present.
# Emits a warning (not an error) if absent — some Ubuntu 24.04 installs use
# nftables as the iptables backend and do not ship the legacy binary.
# Pre:  iptables installed from tier-1.
# Post: /etc/alternatives/iptables → iptables-legacy when available.
function configure_iptables() {
    local legacy="/usr/sbin/iptables-legacy"

    if [[ ! -e "${legacy}" ]]; then
        echo "WARNING: iptables-legacy not found — leaving iptables backend unchanged."
        return 0
    fi

    local current
    current="$(readlink -f /etc/alternatives/iptables 2>/dev/null || true)"
    if [[ "${current}" == "${legacy}" ]]; then
        echo "iptables already in legacy mode."
        return 0
    fi

    echo "Switching iptables to legacy mode..."
    update-alternatives --set iptables "${legacy}"
    if [[ -e /usr/sbin/ip6tables-legacy ]]; then
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    fi
}

# Imports all container images from payload/images/ into the k8s.io
# containerd namespace. Runs on EVERY node regardless of role.
# Workers require pause, kube-proxy, and Calico images in the k8s.io
# namespace before kubeadm join — without this, DaemonSet pods enter
# ImagePullBackOff on an airgapped host.
# Pre:  containerd is active; payload/images/ contains .tar files.
# Post: all payload images visible via `ctr -n k8s.io images ls`.
#
# Idempotency: ctr images import is content-addressed — re-importing an
# already-present image is a fast no-op against the local content store.
# There is no per-image pre-check here intentionally: the overhead is
# negligible and checking would require parsing image refs from tar
# manifests without shell-external tooling.
function import_images() {
    local image_dir="${PAYLOAD_DIR}/images"
    local count
    count=$(find "${image_dir}" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)

    if [[ "${count}" -eq 0 ]]; then
        echo "ERROR: No image tarballs found in ${image_dir}" >&2
        exit 1
    fi

    echo "Importing ${count} container image(s) into k8s.io namespace..."
    while IFS= read -r tar_file; do
        echo "  → $(basename "${tar_file}")"
        ctr -n k8s.io images import "${tar_file}"
    done < <(find "${image_dir}" -maxdepth 1 -name '*.tar' | sort)
}

# ══════════════════════════════════════════════════════════════════════════
# CONTROL PLANE
# ══════════════════════════════════════════════════════════════════════════

# Initialises the Kubernetes control plane via kubeadm. Writes kubeconfigs
# for both the invoking (non-root) user and root. Writes the worker join
# command to JOIN_COMMAND_PATH.
# Pre:  all kube binaries installed; all images imported; containerd active;
#       CONTROL_PLANE_IP, K8S_VERSION, REAL_USER, REAL_HOME are all set.
# Post: /etc/kubernetes/admin.conf exists; kubelet is active;
#       JOIN_COMMAND_PATH is non-empty and contains the join command.
function init_control_plane() {
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        # admin.conf exists but the join command file may be missing if the
        # script was interrupted after kubeadm init but before token creation.
        if [[ ! -s "${JOIN_COMMAND_PATH}" ]]; then
            echo "Control plane already initialised but join command is missing — regenerating..."
            wait_for_apiserver
            local join_cmd
            join_cmd="$(kubeadm token create --print-join-command)"
            echo "JOIN_COMMAND=\"${join_cmd}\"" > "${JOIN_COMMAND_PATH}"
            echo "Join command written to ${JOIN_COMMAND_PATH}"
        else
            echo "Control plane already initialised and join command exists."
        fi
        return 0
    fi

    echo "Initialising control plane..."
    kubeadm init \
        --kubernetes-version="v${K8S_VERSION}" \
        --control-plane-endpoint="${CONTROL_PLANE_IP}" \
        --pod-network-cidr="${POD_NETWORK_CIDR}" \
        --cri-socket="${CRI_SOCKET}" \
        --v=5

    mkdir -p "${REAL_HOME}/.kube"
    cp /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
    chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube"

    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config

    wait_for_apiserver

    local join_cmd
    join_cmd="$(kubeadm token create --print-join-command)"
    echo "JOIN_COMMAND=\"${join_cmd}\"" > "${JOIN_COMMAND_PATH}"
    echo "Join command written to ${JOIN_COMMAND_PATH}"
}

# Polls the API server /healthz endpoint until it responds "ok".
# Uses an explicit --kubeconfig to remove any dependency on /root/.kube/config
# having been written before this function is called.
# Replaces the former unexplained 'sleep 6' which provided no liveness guarantee.
# Pre:  kubeadm init completed; /etc/kubernetes/admin.conf exists.
# Post: API server confirmed healthy; or exits 1 after a 120 s timeout.
function wait_for_apiserver() {
    local timeout=120
    local elapsed=0

    echo "Waiting for API server to become healthy..."
    until kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz &>/dev/null; do
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo "ERROR: API server did not become healthy within ${timeout}s." >&2
            kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /healthz >&2 || true
            exit 1
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    echo "API server is healthy (${elapsed}s elapsed)."
}

# Deploys Calico CNI from payload/manifests/calico.yaml and creates the
# /opt/cni/bin → /usr/lib/cni symlink that Calico's binary CNI plugin needs.
# kubectl apply is idempotent and self-healing, so there is no early-return
# guard — always apply to ensure a partial-failure re-run converges.
# Pre:  control plane initialised; Calico images imported; kubectl working.
# Post: calico-node DaemonSet is applied (pods may still be scheduling on
#       a first run — this is expected and normal).
function install_calico() {
    if [[ ! -e /usr/lib/cni ]]; then
        ln -s /opt/cni/bin /usr/lib/cni
    fi

    local calico_manifest="${PAYLOAD_DIR}/manifests/calico.yaml"
    if [[ ! -f "${calico_manifest}" ]]; then
        echo "ERROR: Calico manifest not found: ${calico_manifest}" >&2
        exit 1
    fi

    echo "Deploying Calico (kubectl apply is idempotent)..."
    kubectl --kubeconfig /etc/kubernetes/admin.conf \
        apply --validate=false -f "${calico_manifest}"
}

# Installs helm and kustomize from payload/optional_tools/ if present.
# No-ops gracefully if the directory or individual tarballs are absent.
# Pre:  running as root on the control plane node.
# Post: helm and kustomize on PATH if their tarballs existed; otherwise no-op.
function install_optional_tools() {
    local tools_dir="${PAYLOAD_DIR}/optional_tools"
    [[ -d "${tools_dir}" ]] || return 0

    if ! command -v helm &>/dev/null && [[ -f "${tools_dir}/helm_bin.tar.gz" ]]; then
        echo "Installing helm..."
        tar -xzf "${tools_dir}/helm_bin.tar.gz" -C "${tools_dir}/"
        mv "${tools_dir}/helm" /usr/local/bin/helm
    fi

    if ! command -v kustomize &>/dev/null && [[ -f "${tools_dir}/kustomize_bin.tar.gz" ]]; then
        echo "Installing kustomize..."
        tar -xzf "${tools_dir}/kustomize_bin.tar.gz" -C "${tools_dir}/"
        mv "${tools_dir}/kustomize" /usr/local/bin/kustomize
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# WORKER
# ══════════════════════════════════════════════════════════════════════════

# Sources the join command from JOIN_COMMAND_PATH and executes it.
# The file is written by init_control_plane() on the control plane and must
# be present on this worker before this function runs (Ansible's worker play
# copies it here before invoking the installer).
# Pre:  all packages installed and images imported; containerd active;
#       JOIN_COMMAND_PATH exists and contains JOIN_COMMAND="kubeadm join ...".
# Post: this worker has joined the cluster; kubelet is active.
function join_worker_node() {
    if systemctl is-active --quiet kubelet && \
       [[ ! -f "${MANIFESTS_PATH}/kube-apiserver.yaml" ]]; then
        echo "Worker already joined and kubelet is active."
        return 0
    fi

    if [[ ! -f "${JOIN_COMMAND_PATH}" ]]; then
        echo "ERROR: Join command file not found: ${JOIN_COMMAND_PATH}" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . "${JOIN_COMMAND_PATH}"

    if [[ -z "${JOIN_COMMAND:-}" ]]; then
        echo "ERROR: JOIN_COMMAND is empty in ${JOIN_COMMAND_PATH}" >&2
        exit 1
    fi

    echo "Joining cluster..."
    # eval is required: JOIN_COMMAND is a multi-word kubeadm command string
    # with flags that must be word-split correctly at execution time.
    # shellcheck disable=SC2209
    eval "${JOIN_COMMAND}"
}

# Attempts to restart an inactive kubelet on a worker that was previously
# joined. Does NOT reinstall packages, re-import images, or rejoin the cluster.
# Pre:  kubelet binary installed; node previously joined (no manifest files).
# Post: kubelet is active; or exits 1 with diagnostic instructions.
function recover_worker() {
    echo "Worker kubelet is inactive — attempting restart..."
    systemctl start kubelet

    local retries=10
    while [[ ${retries} -gt 0 ]]; do
        if systemctl is-active --quiet kubelet; then
            echo "kubelet restarted successfully."
            return 0
        fi
        retries=$(( retries - 1 ))
        sleep 2
    done

    echo "ERROR: kubelet did not become active after restart." >&2
    echo "Run 'journalctl -u kubelet --no-pager -n 50' for details." >&2
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════
# ORCHESTRATION
# ══════════════════════════════════════════════════════════════════════════

# Runs the full installation sequence for a fresh node (no k8s binaries present).
# Called only from check_node() when neither kubeadm nor kubelet is on PATH.
# Pre:  validate_environment() passed; ROLE is 'control_plane' or 'worker'.
# Post: control plane initialised + Calico deployed, OR worker joined cluster.
function install_k8s() {
    local role="$1"

    disable_swap
    install_os_deps
    install_containerd
    install_cni
    install_cri_tools
    install_kube_binaries
    configure_kernel
    configure_iptables

    # Images MUST be imported before any kubeadm operation.
    # Workers need pause, kube-proxy, and Calico images in the k8s.io
    # namespace before kubeadm join; control plane needs all init images.
    import_images

    if [[ "${role}" == "control_plane" ]]; then
        init_control_plane
        install_calico
        install_optional_tools
    else
        join_worker_node
    fi
}

# Determines the current node state and routes to the appropriate action.
# This is the top-level decision function for all fresh-install and re-run paths.
# Pre:  validate_environment() passed; ROLE is set.
# Post: exits 0 for all success paths; exits 1 for unrecoverable states.
function check_node() {
    # ── Case 1: fresh node — either binary absent ──────────────────────────
    if ! command -v kubeadm &>/dev/null || ! command -v kubelet &>/dev/null; then
        echo "k8s not installed — starting fresh installation (role: ${ROLE})..."
        install_k8s "${ROLE}"
        return 0
    fi

    # ── Classify by presence of control-plane static pod manifests ─────────
    local is_control_plane=false
    if [[ -f "${MANIFESTS_PATH}/kube-apiserver.yaml" ]]          || \
       [[ -f "${MANIFESTS_PATH}/kube-scheduler.yaml" ]]           || \
       [[ -f "${MANIFESTS_PATH}/kube-controller-manager.yaml" ]]; then
        is_control_plane=true
    fi

    if [[ "${is_control_plane}" == "true" ]]; then
        # ── Case 2: control plane ──────────────────────────────────────────
        if systemctl is-active --quiet kubelet; then
            echo "Control plane is already running — re-run is a no-op."
            exit 0
        else
            echo "ERROR: Control-plane manifests present but kubelet is inactive." >&2
            echo "Manual investigation required." >&2
            echo "Run: journalctl -u kubelet --no-pager -n 50" >&2
            exit 1
        fi
    else
        # ── Case 3: worker (no manifest files) ────────────────────────────
        if systemctl is-active --quiet kubelet; then
            echo "Worker already joined and running — re-run is a no-op."
            exit 0
        else
            recover_worker
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════

function main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--role)
                [[ $# -ge 2 ]] || { echo "ERROR: --role requires a value." >&2; exit 1; }
                ROLE="$2"
                shift 2
                ;;
            -m|--master)
                [[ $# -ge 2 ]] || { echo "ERROR: --master requires a value." >&2; exit 1; }
                CONTROL_PLANE_IP="$2"
                shift 2
                ;;
            --debug)
                set -x
                shift
                ;;
            *)
                echo "WARNING: ignoring unrecognized argument: $1" >&2
                shift
                ;;
        esac
    done

    resolve_real_user
    validate_environment
    check_node
}

main "$@"
