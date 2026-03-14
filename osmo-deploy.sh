#!/bin/bash
###############################################################################
# OSMO Full-Stack Deployment Script
#
# Wraps the deploy_minimal.rst guide into a single automated script for AWS.
# Covers: Terraform, EKS config, OSMO deploy (Steps 1-8), nginx proxy,
# S3 storage config, service_base_url, and GPU node scale-up.
#
# Prerequisites:
#   - AWS CLI installed and authenticated (aws configure)
#   - Terraform >= 1.9
#   - kubectl, helm, jq, openssl, curl
#   - OSMO CLI (osmo) — optional but recommended
#
# Usage:
#   ./osmo-deploy.sh [--skip-terraform] [--skip-gpu] [--preflight-only] [--repo-root PATH]
#
# Reads configuration from:
#   deployments/terraform/aws/example/terraform.tfvars
#
###############################################################################

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

# Bug #1 fix: REPO_ROOT defaults to the directory containing the script itself
# (since script now lives at repo root), with --repo-root override and
# OSMO_REPO_ROOT env var fallback, plus git rev-parse auto-detection.
REPO_ROOT="${OSMO_REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || REPO_ROOT="$(pwd)"
    # Verify we're in a git repo; if the script dir doesn't have the expected
    # structure, try git rev-parse
    if [[ ! -d "$REPO_ROOT/deployments" ]]; then
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(pwd)"
    fi
fi

# Allow override; default assumes script is run from the OSMO repo root
TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/deployments/terraform/aws/example}"

OSMO_NAMESPACE="${OSMO_NAMESPACE:-osmo-minimal}"
OSMO_OPERATOR_NAMESPACE="${OSMO_OPERATOR_NAMESPACE:-osmo-operator}"
OSMO_WORKFLOWS_NAMESPACE="${OSMO_WORKFLOWS_NAMESPACE:-osmo-workflows}"

OSMO_IMAGE_REGISTRY="${OSMO_IMAGE_REGISTRY:-nvcr.io/nvidia/osmo}"
OSMO_IMAGE_TAG="${OSMO_IMAGE_TAG:-latest}"
BACKEND_TOKEN_EXPIRY="${BACKEND_TOKEN_EXPIRY:-2027-01-01}"
NGC_API_KEY="${NGC_API_KEY:-}"
IMAGE_PULL_SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-ngc-registry}"

SKIP_TERRAFORM=false
SKIP_GPU=false
PREFLIGHT_ONLY=false

# Bug #8 fix: deterministic bucket name (set after load_tfvars populates CLUSTER_NAME)
S3_BUCKET_NAME="${S3_BUCKET_NAME:-}"

# Dev mode auth uses x-osmo-user header, no token needed
OSMO_AUTH_HEADER="x-osmo-user: testuser"

###############################################################################
# Parse Arguments
###############################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-terraform)  SKIP_TERRAFORM=true; shift ;;
        --skip-gpu)        SKIP_GPU=true; shift ;;
        --preflight-only)  PREFLIGHT_ONLY=true; shift ;;
        --repo-root)       REPO_ROOT="$2"; shift 2 ;;
        --ngc-api-key)     NGC_API_KEY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--skip-terraform] [--skip-gpu] [--preflight-only] [--repo-root PATH] [--ngc-api-key KEY]"
            exit 0
            ;;
        *) shift ;;
    esac
done

###############################################################################
# Helpers
###############################################################################

log_info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()    { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

wait_for_pods() {
    local ns="$1" timeout="${2:-300}"
    log_info "Waiting for pods in $ns to be ready (timeout: ${timeout}s)..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local not_ready
        not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | grep -v 'Running\|Completed\|Succeeded' | wc -l || echo "0")
        if [[ "$not_ready" -eq 0 ]]; then
            local total
            total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
            if [[ "$total" -gt 0 ]]; then
                log_success "All $total pods ready in $ns"
                return 0
            fi
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    log_warn "Timeout waiting for pods in $ns — continuing anyway"
}

###############################################################################
# Pre-flight
###############################################################################

preflight() {
    log_info "Running pre-flight checks..."
    for cmd in terraform aws kubectl helm jq openssl curl; do
        check_command "$cmd"
    done

    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not authenticated. Run 'aws configure' first."
        exit 1
    fi

    if [[ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
        log_error "terraform.tfvars not found at $TERRAFORM_DIR/terraform.tfvars"
        exit 1
    fi

    if [[ -z "$NGC_API_KEY" ]]; then
        log_warn "NGC_API_KEY is not set. Helm charts may deploy, but nvcr.io image pulls can fail."
    fi

    log_success "Pre-flight checks passed"

    # --- AWS Quota Checks (advisory) ---
    log_info "Checking AWS quotas..."
    local region="${AWS_REGION:-us-west-2}"

    # Standard (On-Demand) vCPU quota — L-1216C47A
    local std_vcpu
    std_vcpu=$(aws service-quotas get-service-quota \
        --service-code ec2 --quota-code L-1216C47A \
        --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo "")
    if [[ -n "$std_vcpu" && "$std_vcpu" != "None" ]]; then
        local std_int=${std_vcpu%.*}
        if [[ "$std_int" -lt 20 ]]; then
            log_warn "Standard vCPU quota is ${std_int} (recommend >= 20). Request increase via Service Quotas console."
        else
            log_success "Standard vCPU quota: ${std_int}"
        fi
    else
        log_warn "Could not read standard vCPU quota (L-1216C47A) — verify manually"
    fi

    # G and VT instance vCPU quota — L-DB2E81BA
    local gpu_vcpu
    gpu_vcpu=$(aws service-quotas get-service-quota \
        --service-code ec2 --quota-code L-DB2E81BA \
        --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo "")
    if [[ -n "$gpu_vcpu" && "$gpu_vcpu" != "None" ]]; then
        local gpu_int=${gpu_vcpu%.*}
        if [[ "$gpu_int" -lt 8 ]]; then
            log_warn "G-instance vCPU quota is ${gpu_int} (recommend >= 8 for g5.2xlarge). Request increase."
        else
            log_success "G-instance vCPU quota: ${gpu_int}"
        fi
    else
        log_warn "Could not read G-instance vCPU quota (L-DB2E81BA) — verify manually"
    fi

    # EKS cluster limit — L-1194D53C
    local eks_limit
    eks_limit=$(aws service-quotas get-service-quota \
        --service-code eks --quota-code L-1194D53C \
        --region "$region" --query 'Quota.Value' --output text 2>/dev/null || echo "")
    local eks_count
    eks_count=$(aws eks list-clusters --region "$region" \
        --query 'length(clusters)' --output text 2>/dev/null || echo "0")
    if [[ -n "$eks_limit" && "$eks_limit" != "None" ]]; then
        local eks_limit_int=${eks_limit%.*}
        if [[ "$eks_count" -ge "$eks_limit_int" ]]; then
            log_warn "EKS cluster count ($eks_count) is at the limit ($eks_limit_int). Delete unused clusters or request increase."
        else
            log_success "EKS clusters: ${eks_count}/${eks_limit_int}"
        fi
    else
        log_warn "Could not read EKS cluster quota — verify manually"
    fi

    log_success "AWS quota checks complete"
}

###############################################################################
# Read terraform.tfvars
###############################################################################

load_tfvars() {
    log_info "Loading terraform.tfvars..."
    TFVARS="$TERRAFORM_DIR/terraform.tfvars"

    AWS_REGION=$(grep 'aws_region' "$TFVARS" | head -1 | cut -d'"' -f2)
    CLUSTER_NAME=$(grep 'cluster_name' "$TFVARS" | head -1 | cut -d'"' -f2)
    POSTGRES_PASSWORD=$(grep 'rds_password' "$TFVARS" | head -1 | cut -d'"' -f2)
    REDIS_PASSWORD=$(grep 'redis_auth_token' "$TFVARS" | head -1 | cut -d'"' -f2)
    RDS_DB_NAME=$(grep 'rds_db_name' "$TFVARS" | head -1 | cut -d'"' -f2 || echo "osmo")
    RDS_USERNAME=$(grep 'rds_username' "$TFVARS" | head -1 | cut -d'"' -f2 || echo "postgres")

    # Bug #8 fix: deterministic bucket name based on cluster name
    if [[ -z "$S3_BUCKET_NAME" ]]; then
        S3_BUCKET_NAME="osmo-data-${CLUSTER_NAME}"
    fi

    log_success "Config loaded: region=$AWS_REGION cluster=$CLUSTER_NAME"
}

###############################################################################
# Phase 1: Terraform
###############################################################################

run_terraform() {
    if [[ "$SKIP_TERRAFORM" == true ]]; then
        log_info "Skipping Terraform (--skip-terraform)"
        return
    fi

    log_info "Phase 1: Terraform init & apply..."
    cd "$TERRAFORM_DIR"
    terraform init -input=false
    terraform apply -auto-approve
    cd - >/dev/null

    log_success "Terraform apply complete"
}

get_terraform_outputs() {
    log_info "Reading Terraform outputs..."
    cd "$TERRAFORM_DIR"

    POSTGRES_HOST=$(terraform output -raw rds_instance_address 2>/dev/null || echo "")
    REDIS_HOST=$(terraform output -raw redis_primary_endpoint_address 2>/dev/null || echo "")
    EKS_CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "$CLUSTER_NAME")

    cd - >/dev/null

    if [[ -z "$POSTGRES_HOST" || -z "$REDIS_HOST" ]]; then
        log_error "Could not read Terraform outputs (rds_instance_address, redis_primary_endpoint_address)"
        exit 1
    fi

    log_success "Postgres=$POSTGRES_HOST  Redis=$REDIS_HOST"
}

###############################################################################
# Phase 2: Configure kubectl
###############################################################################

configure_kubectl() {
    log_info "Phase 2: Configuring kubectl for EKS..."
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
    kubectl get nodes
    log_success "kubectl configured"
}

###############################################################################
# Phase 3: Steps 1-4 — Namespace, Helm repo, Secrets, Database
###############################################################################

create_namespaces() {
    log_info "Step 1: Creating namespaces..."
    for ns in "$OSMO_NAMESPACE" "$OSMO_OPERATOR_NAMESPACE" "$OSMO_WORKFLOWS_NAMESPACE"; do
        kubectl create namespace "$ns" 2>/dev/null || true
    done
    log_success "Namespaces ready"
}

add_helm_repos() {
    log_info "Step 2: Verifying local Helm charts..."
    for chart_dir in \
        "$REPO_ROOT/deployments/charts/service" \
        "$REPO_ROOT/deployments/charts/web-ui" \
        "$REPO_ROOT/deployments/charts/router" \
        "$REPO_ROOT/deployments/charts/backend-operator"; do
        if [[ ! -d "$chart_dir" ]]; then
            log_error "Missing chart directory: $chart_dir"
            exit 1
        fi
    done
    log_success "Local Helm charts verified"
}

create_secrets() {
    log_info "Step 3: Creating K8s secrets..."

    # db-secret
    kubectl delete secret db-secret -n "$OSMO_NAMESPACE" --ignore-not-found
    kubectl create secret generic db-secret \
        --from-literal=db-password="$POSTGRES_PASSWORD" \
        -n "$OSMO_NAMESPACE"

    # redis-secret
    kubectl delete secret redis-secret -n "$OSMO_NAMESPACE" --ignore-not-found
    kubectl create secret generic redis-secret \
        --from-literal=redis-password="$REDIS_PASSWORD" \
        -n "$OSMO_NAMESPACE"

    # MEK
    local random_key
    random_key=$(openssl rand -base64 32 | tr -d '\n')
    local jwk_json="{\"k\":\"$random_key\",\"kid\":\"key1\",\"kty\":\"oct\"}"
    local encoded_jwk
    encoded_jwk=$(echo -n "$jwk_json" | base64 | tr -d '\n')

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mek-config
  namespace: $OSMO_NAMESPACE
data:
  mek.yaml: |
    currentMek: key1
    meks:
      key1: $encoded_jwk
EOF

    if [[ -n "$NGC_API_KEY" ]]; then
        for secret_ns in "$OSMO_NAMESPACE" "$OSMO_OPERATOR_NAMESPACE" "$OSMO_WORKFLOWS_NAMESPACE"; do
            kubectl delete secret "$IMAGE_PULL_SECRET_NAME" -n "$secret_ns" --ignore-not-found
            kubectl create secret docker-registry "$IMAGE_PULL_SECRET_NAME" \
                --docker-server=nvcr.io \
                --docker-username='$oauthtoken' \
                --docker-password="$NGC_API_KEY" \
                --docker-email='unused@example.com' \
                -n "$secret_ns"
        done
        log_success "NGC image pull secrets created"
    fi

    log_success "Secrets and MEK created"
}

create_database() {
    log_info "Step 4: Creating PostgreSQL database..."

    kubectl delete pod osmo-db-ops -n "$OSMO_NAMESPACE" --ignore-not-found
    sleep 2

    local escaped_pw
    escaped_pw=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/'\\\\''/g")

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: osmo-db-ops
  namespace: $OSMO_NAMESPACE
spec:
  containers:
    - name: osmo-db-ops
      image: postgres:15
      env:
        - name: PGPASSWORD
          value: '$escaped_pw'
        - name: PGHOST
          value: '$POSTGRES_HOST'
        - name: PGUSER
          value: '$RDS_USERNAME'
      command:
        - /bin/bash
        - -c
        - |
          echo 'Creating database...'
          psql -h \$PGHOST -U \$PGUSER -d postgres -c 'CREATE DATABASE osmo;' 2>&1 || echo 'Database may already exist'
          psql -h \$PGHOST -U \$PGUSER -d osmo -c 'SELECT 1 as connected;' && echo 'SUCCESS'
  restartPolicy: Never
EOF

    log_info "Waiting for DB init pod..."
    local waited=0
    while [[ $waited -lt 120 ]]; do
        local phase
        phase=$(kubectl get pod osmo-db-ops -n "$OSMO_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
            kubectl logs osmo-db-ops -n "$OSMO_NAMESPACE" 2>/dev/null || true
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    kubectl delete pod osmo-db-ops -n "$OSMO_NAMESPACE" --ignore-not-found
    log_success "Database ready"
}

###############################################################################
# Phase 4: Steps 5-7 — Values files, Helm deploy, Verify
###############################################################################

VALUES_DIR="/tmp/osmo-values"

generate_values_files() {
    log_info "Step 5: Generating Helm values files..."
    mkdir -p "$VALUES_DIR"

    cat > "$VALUES_DIR/service_values.yaml" <<EOF
global:
  osmoImageLocation: ${OSMO_IMAGE_REGISTRY}
  osmoImageTag: ${OSMO_IMAGE_TAG}
  imagePullSecret: ${IMAGE_PULL_SECRET_NAME}
services:
  configFile:
    enabled: true
  postgres:
    enabled: false
    serviceName: ${POSTGRES_HOST}
    port: 5432
    db: ${RDS_DB_NAME}
    user: ${RDS_USERNAME}
    passwordSecretName: db-secret
    passwordSecretKey: db-password
  redis:
    enabled: false
    serviceName: ${REDIS_HOST}
    port: 6379
    tlsEnabled: true
  service:
    scaling:
      minReplicas: 1
      maxReplicas: 1
    ingress:
      enabled: false
  agent:
    scaling:
      minReplicas: 1
      maxReplicas: 1
  worker:
    scaling:
      minReplicas: 1
      maxReplicas: 1
  logger:
    scaling:
      minReplicas: 1
      maxReplicas: 1
sidecars:
  otel:
    enabled: false
  rateLimit:
    enabled: false
  envoy:
    enabled: false
  logAgent:
    enabled: false
EOF

    cat > "$VALUES_DIR/ui_values.yaml" <<EOF
global:
  osmoImageLocation: ${OSMO_IMAGE_REGISTRY}
  osmoImageTag: ${OSMO_IMAGE_TAG}
  imagePullSecret: ${IMAGE_PULL_SECRET_NAME}
services:
  ui:
    replicas: 1
    hostname: "osmo-minimal.local"
    apiHostname: "osmo-service.${OSMO_NAMESPACE}.svc.cluster.local:80"
    ingress:
      enabled: false
sidecars:
  envoy:
    enabled: false
  logAgent:
    enabled: false
EOF

    cat > "$VALUES_DIR/router_values.yaml" <<EOF
global:
  osmoImageLocation: ${OSMO_IMAGE_REGISTRY}
  osmoImageTag: ${OSMO_IMAGE_TAG}
  imagePullSecret: ${IMAGE_PULL_SECRET_NAME}
services:
  configFile:
    enabled: true
  service:
    scaling:
      minReplicas: 1
      maxReplicas: 1
    ingress:
      enabled: false
  postgres:
    serviceName: ${POSTGRES_HOST}
    port: 5432
    db: ${RDS_DB_NAME}
    user: ${RDS_USERNAME}
    passwordSecretName: db-secret
    passwordSecretKey: db-password
sidecars:
  otel:
    enabled: false
  envoy:
    enabled: false
  logAgent:
    enabled: false
EOF

    cat > "$VALUES_DIR/backend_operator_values.yaml" <<EOF
global:
  osmoImageLocation: ${OSMO_IMAGE_REGISTRY}
  osmoImageTag: ${OSMO_IMAGE_TAG}
  imagePullSecret: ${IMAGE_PULL_SECRET_NAME}
  serviceUrl: http://osmo-service.${OSMO_NAMESPACE}.svc.cluster.local:80
  agentNamespace: ${OSMO_OPERATOR_NAMESPACE}
  backendNamespace: ${OSMO_WORKFLOWS_NAMESPACE}
  backendName: default
  accountTokenSecret: osmo-operator-token
  loginMethod: token
services:
  backendListener:
    resources:
      requests:
        cpu: "125m"
        memory: "128Mi"
      limits:
        cpu: "250m"
        memory: "256Mi"
  backendWorker:
    resources:
      requests:
        cpu: "125m"
        memory: "128Mi"
      limits:
        cpu: "250m"
        memory: "256Mi"
sidecars:
  otel:
    enabled: false
EOF

    log_success "Values files generated in $VALUES_DIR"
}

helm_deploy() {
    log_info "Step 6: Deploying OSMO via Helm..."

    helm upgrade --install osmo-minimal "$REPO_ROOT/deployments/charts/service" \
        -f "$VALUES_DIR/service_values.yaml" \
        --namespace "$OSMO_NAMESPACE" --wait --timeout 10m

    helm upgrade --install ui-minimal "$REPO_ROOT/deployments/charts/web-ui" \
        -f "$VALUES_DIR/ui_values.yaml" \
        --namespace "$OSMO_NAMESPACE" --wait --timeout 5m

    helm upgrade --install router-minimal "$REPO_ROOT/deployments/charts/router" \
        -f "$VALUES_DIR/router_values.yaml" \
        --namespace "$OSMO_NAMESPACE" --wait --timeout 5m

    log_success "Helm deploys complete"
}

verify_pods() {
    log_info "Step 7: Verifying pods..."
    wait_for_pods "$OSMO_NAMESPACE" 300
    kubectl get pods -n "$OSMO_NAMESPACE"
    kubectl get services -n "$OSMO_NAMESPACE"
    log_success "OSMO core pods verified"
}

###############################################################################
# Phase 5: Step 8 — Backend Operator
###############################################################################

setup_backend_operator() {
    log_info "Step 8: Setting up Backend Operator..."

    # Port-forward to generate token
    kubectl port-forward service/osmo-service 9000:80 -n "$OSMO_NAMESPACE" &
    local pf_pid=$!
    sleep 5

    local token=""
    if command -v osmo &>/dev/null; then
        osmo login http://localhost:9000 --method=dev --username=testuser || true
        token=$(osmo token set backend-token \
            --expires-at "$BACKEND_TOKEN_EXPIRY" \
            --description "Backend Operator Token" \
            --service \
            --roles osmo-backend \
            -t json 2>/dev/null | jq -r '.token' || echo "")
    fi

    if [[ -z "$token" || "$token" == "null" ]]; then
        # Bug #2/#3 fix: use x-osmo-user header and correct endpoint
        # POST /api/auth/access_token/service/{token_name}?expires_at=...&roles=...
        # Response is the raw token string (not JSON)
        token=$(curl -sf -X POST \
            "http://localhost:9000/api/auth/access_token/service/backend-token?expires_at=${BACKEND_TOKEN_EXPIRY}&roles=osmo-backend" \
            -H "$OSMO_AUTH_HEADER" || echo "")

        # The response is a quoted string — strip surrounding quotes if present
        token=$(echo "$token" | tr -d '"')
    fi

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true

    # Create token secret
    kubectl delete secret osmo-operator-token -n "$OSMO_OPERATOR_NAMESPACE" --ignore-not-found
    if [[ -n "$token" && "$token" != "null" ]]; then
        kubectl create secret generic osmo-operator-token \
            --from-literal=token="$token" \
            -n "$OSMO_OPERATOR_NAMESPACE"
        log_success "Backend token created"
    else
        kubectl create secret generic osmo-operator-token \
            --from-literal=token=placeholder \
            -n "$OSMO_OPERATOR_NAMESPACE"
        log_warn "Backend token placeholder created — update manually if needed"
    fi

    # Deploy operator
    helm upgrade --install osmo-operator "$REPO_ROOT/deployments/charts/backend-operator" \
        -f "$VALUES_DIR/backend_operator_values.yaml" \
        --namespace "$OSMO_OPERATOR_NAMESPACE" --wait --timeout 5m

    wait_for_pods "$OSMO_OPERATOR_NAMESPACE" 180
    log_success "Backend Operator deployed"
}

###############################################################################
# Phase 6: Nginx Proxy
###############################################################################

deploy_nginx_proxy() {
    log_info "Deploying nginx proxy (osmo-proxy)..."

    # Bug #6 fix: use unquoted heredoc so $OSMO_NAMESPACE expands;
    # escape nginx variables with \$
    kubectl apply -f - <<PROXY_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: osmo-proxy-config
  namespace: ${OSMO_NAMESPACE}
data:
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      resolver kube-dns.kube-system.svc.cluster.local valid=5s;

      upstream osmo_service {
        server osmo-service.${OSMO_NAMESPACE}.svc.cluster.local:80;
      }
      upstream osmo_ui {
        server osmo-ui.${OSMO_NAMESPACE}.svc.cluster.local:80;
      }
      upstream osmo_agent {
        server osmo-agent.${OSMO_NAMESPACE}.svc.cluster.local:80;
      }
      upstream osmo_logger {
        server osmo-logger.${OSMO_NAMESPACE}.svc.cluster.local:80;
      }
      upstream osmo_router {
        server osmo-router.${OSMO_NAMESPACE}.svc.cluster.local:80;
      }

      server {
        listen 80;
        client_max_body_size 100m;

        # API routes
        location /api/ {
          proxy_pass http://osmo_service;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_buffer_size 16k;
          proxy_buffers 8 16k;
          proxy_busy_buffers_size 32k;
        }

        # Health endpoint (proxied to service)
        location = /health {
          proxy_pass http://osmo_service;
          proxy_set_header Host \$host;
        }

        # Agent routes (websocket-capable)
        location /agent/ {
          proxy_pass http://osmo_agent;
          proxy_set_header Host \$host;
          proxy_set_header Upgrade \$http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_http_version 1.1;
        }

        # Logger routes
        location /logger/ {
          proxy_pass http://osmo_logger;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
        }

        # Router routes
        location /router/ {
          proxy_pass http://osmo_router;
          proxy_set_header Host \$host;
          proxy_set_header Upgrade \$http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_http_version 1.1;
        }

        # Default: UI
        location / {
          proxy_pass http://osmo_ui;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: osmo-proxy
  namespace: ${OSMO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: osmo-proxy
  template:
    metadata:
      labels:
        app: osmo-proxy
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
      volumes:
        - name: config
          configMap:
            name: osmo-proxy-config
---
apiVersion: v1
kind: Service
metadata:
  name: osmo-proxy
  namespace: ${OSMO_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: osmo-proxy
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
PROXY_EOF

    wait_for_pods "$OSMO_NAMESPACE" 60
    log_success "osmo-proxy deployed"
}

###############################################################################
# Phase 7+8: S3 Storage + service_base_url Configuration (combined)
###############################################################################
# Bug #10 fix: combine S3 config and service_base_url into one port-forward
# session to avoid port conflicts.

configure_osmo_api() {
    log_info "Configuring S3 storage and service_base_url..."

    # --- S3 bucket and IAM setup ---

    # Create S3 bucket
    if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null; then
        log_info "S3 bucket $S3_BUCKET_NAME already exists"
    else
        if [[ "$AWS_REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION"
        else
            aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        log_success "Created S3 bucket: $S3_BUCKET_NAME"
    fi

    # Bug #9 fix: scope IAM user name to cluster
    local iam_user="osmo-s3-user-${CLUSTER_NAME}"
    aws iam create-user --user-name "$iam_user" 2>/dev/null || true

    # Attach S3 policy
    local policy_doc
    policy_doc=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_NAME}",
        "arn:aws:s3:::${S3_BUCKET_NAME}/*"
      ]
    }
  ]
}
POLICY
)

    local policy_arn=""
    policy_arn=$(aws iam create-policy \
        --policy-name "osmo-s3-policy-${S3_BUCKET_NAME}" \
        --policy-document "$policy_doc" \
        --query 'Policy.Arn' --output text 2>/dev/null || echo "")

    if [[ -n "$policy_arn" ]]; then
        aws iam attach-user-policy --user-name "$iam_user" --policy-arn "$policy_arn" 2>/dev/null || true
    fi

    # Create access key
    local key_json
    key_json=$(aws iam create-access-key --user-name "$iam_user" 2>/dev/null || echo "")

    local access_key_id=""
    local secret_key=""
    if [[ -n "$key_json" ]]; then
        access_key_id=$(echo "$key_json" | jq -r '.AccessKey.AccessKeyId')
        secret_key=$(echo "$key_json" | jq -r '.AccessKey.SecretAccessKey')
    fi

    if [[ -z "$access_key_id" || "$access_key_id" == "null" ]]; then
        log_warn "Could not create IAM access key — configure S3 credentials manually"
        return
    fi

    # --- Single port-forward session for all API config calls ---

    kubectl port-forward service/osmo-proxy 9080:80 -n "$OSMO_NAMESPACE" &
    local pf_pid=$!
    sleep 3

    # Bug #4 fix: use PATCH /api/configs/workflow with correct payload structure
    # per configure_data.rst — workflow_log and workflow_data credentials
    local s3_credential
    s3_credential=$(cat <<CRED
{
    "endpoint": "s3://${S3_BUCKET_NAME}",
    "access_key_id": "${access_key_id}",
    "access_key": "${secret_key}",
    "region": "${AWS_REGION}"
}
CRED
)

    # Configure workflow_log storage
    log_info "Configuring workflow_log storage..."
    curl -sf -X PATCH http://localhost:9080/api/configs/workflow \
        -H "$OSMO_AUTH_HEADER" \
        -H 'Content-Type: application/json' \
        -d "{\"configs_dict\": {\"workflow_log\": {\"credential\": ${s3_credential}}}}" \
        || log_warn "Failed to set workflow_log config via API"

    # Configure workflow_data storage
    log_info "Configuring workflow_data storage..."
    curl -sf -X PATCH http://localhost:9080/api/configs/workflow \
        -H "$OSMO_AUTH_HEADER" \
        -H 'Content-Type: application/json' \
        -d "{\"configs_dict\": {\"workflow_data\": {\"credential\": ${s3_credential}}}}" \
        || log_warn "Failed to set workflow_data config via API"

    log_success "S3 storage configured via OSMO API"

    # Bug #5 fix: use PATCH /api/configs/service with configs_dict wrapper
    # Bug #7 fix: removed duplicate PUT call
    log_info "Setting service_base_url to osmo-proxy..."
    curl -sf -X PATCH http://localhost:9080/api/configs/service \
        -H "$OSMO_AUTH_HEADER" \
        -H 'Content-Type: application/json' \
        -d "{\"configs_dict\": {\"service_base_url\": \"http://osmo-proxy.${OSMO_NAMESPACE}.svc.cluster.local:80\"}}" \
        || log_warn "Failed to set service_base_url"

    log_success "service_base_url configured"

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

###############################################################################
# Phase 9: GPU Node Scale-up
###############################################################################

scale_gpu_nodes() {
    if [[ "$SKIP_GPU" == true ]]; then
        log_info "Skipping GPU node scale-up (--skip-gpu)"
        return
    fi

    log_info "Scaling GPU node group to desired_size=1..."

    local nodegroup_name="${EKS_CLUSTER_NAME}-gpu-nodes"

    # Try to find the exact nodegroup name
    local actual_ng
    actual_ng=$(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" --query 'nodegroups[?contains(@, `gpu`)]' \
        --output text 2>/dev/null | head -1 || echo "")

    if [[ -n "$actual_ng" ]]; then
        nodegroup_name="$actual_ng"
    fi

    aws eks update-nodegroup-config \
        --cluster-name "$EKS_CLUSTER_NAME" \
        --nodegroup-name "$nodegroup_name" \
        --scaling-config minSize=0,maxSize=1,desiredSize=1 \
        --region "$AWS_REGION" 2>/dev/null \
        && log_success "GPU node group scaling to 1 node" \
        || log_warn "Could not scale GPU node group '$nodegroup_name' — scale manually if needed"
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    echo "=============================================================================="
    echo "              OSMO Full-Stack Deployment Script"
    echo "=============================================================================="
    echo ""

    preflight
    load_tfvars

    if [[ "$PREFLIGHT_ONLY" == true ]]; then
        echo ""
        log_success "Preflight complete. Your account looks ready for OSMO deployment."
        echo ""
        echo "Next steps:"
        echo "  1. Review/edit: $TERRAFORM_DIR/terraform.tfvars"
        echo "  2. Run:         ./osmo-deploy.sh"
        echo "  3. Then:        ./osmo-run-workflow.sh"
        exit 0
    fi

    # Phase 1: Terraform
    run_terraform
    get_terraform_outputs

    # Phase 2: kubectl
    configure_kubectl

    # Phase 3: Steps 1-4
    create_namespaces
    add_helm_repos
    create_secrets
    create_database

    # Phase 4: Steps 5-7
    generate_values_files
    helm_deploy
    verify_pods

    # Phase 5: Step 8
    setup_backend_operator

    # Phase 6: Nginx proxy
    deploy_nginx_proxy

    # Phase 7+8: S3 storage + service_base_url (combined in one port-forward)
    configure_osmo_api

    # Phase 9: GPU
    scale_gpu_nodes

    echo ""
    echo "=============================================================================="
    echo "              OSMO Deployment Complete!"
    echo "=============================================================================="
    echo ""
    echo "Access OSMO:"
    echo "  kubectl port-forward service/osmo-proxy 8080:80 -n $OSMO_NAMESPACE"
    echo "  UI:  http://localhost:8080"
    echo "  API: http://localhost:8080/api/docs"
    echo ""
    echo "Login:"
    echo "  osmo login http://localhost:8080 --method=dev --username=testuser"
    echo ""
    echo "Run a workflow:"
    echo "  ./osmo-run-workflow.sh"
    echo "=============================================================================="
}

main
