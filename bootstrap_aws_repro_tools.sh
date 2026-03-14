#!/usr/bin/env bash
#
# Install the local toolchain needed to run the AWS/EKS nut-pouring reproduction
# from a fresh workstation or SageMaker notebook instance.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.2}"
HELM_VERSION="${HELM_VERSION:-v3.17.2}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.11.1}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log_info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

need_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing required bootstrap dependency: $1"
        exit 1
    fi
}

install_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        log_info "kubectl already installed"
        return
    fi
    curl -fsSLo "${INSTALL_DIR}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x "${INSTALL_DIR}/kubectl"
    log_success "Installed kubectl to ${INSTALL_DIR}/kubectl"
}

install_helm() {
    if command -v helm >/dev/null 2>&1; then
        log_info "helm already installed"
        return
    fi
    local archive="/tmp/helm-${HELM_VERSION}.tar.gz"
    curl -fsSLo "${archive}" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    tar -xzf "${archive}" -C /tmp
    install -m 0755 /tmp/linux-amd64/helm "${INSTALL_DIR}/helm"
    rm -rf /tmp/linux-amd64 "${archive}"
    log_success "Installed helm to ${INSTALL_DIR}/helm"
}

install_terraform() {
    if command -v terraform >/dev/null 2>&1; then
        log_info "terraform already installed"
        return
    fi
    local archive="/tmp/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    curl -fsSLo "${archive}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    unzip -oq "${archive}" -d "${INSTALL_DIR}"
    chmod +x "${INSTALL_DIR}/terraform"
    rm -f "${archive}"
    log_success "Installed terraform to ${INSTALL_DIR}/terraform"
}

install_python_deps() {
    "${PYTHON_BIN}" -m pip install --user --disable-pip-version-check \
        python-pptx==1.0.2 \
        pyyaml==6.0.3 \
        pillow==12.1.0 \
        h5py==3.11.0 \
        opencv-python-headless==4.10.0.84
    log_success "Installed Python report/evidence dependencies"
}

print_next_steps() {
    cat <<EOF

Add this to your shell if ${INSTALL_DIR} is not already on PATH:
  export PATH="${INSTALL_DIR}:\$PATH"

Then verify:
  kubectl version --client
  helm version
  terraform version
  ${PYTHON_BIN} -c "import pptx, yaml, h5py, cv2; print('python deps OK')"
EOF
}

main() {
    mkdir -p "${INSTALL_DIR}"
    need_command curl
    need_command tar
    need_command unzip
    need_command "${PYTHON_BIN}"
    install_kubectl
    install_helm
    install_terraform
    install_python_deps
    print_next_steps
}

main "$@"
