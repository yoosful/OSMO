#!/usr/bin/env bash
#
# OSMO AWS idle autoscaler:
# - Detects active OSMO workflows via API.
# - After an idle timeout, scales expensive nodegroups down.
# - Optionally installs a cron job so this is automatic.
#
# Default behavior:
# - GPU/GROOT nodegroups (name matches "gpu|groot"): desired=0
# - CPU nodegroup(s) (name matches "nodes" but not GPU/GROOT): desired=1
#
# Requirements:
# - aws, kubectl, jq, curl
# - kubectl access to the target cluster
# - permissions for aws eks:ListNodegroups/DescribeNodegroup/UpdateNodegroupConfig

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
OSMO_NAMESPACE="${OSMO_NAMESPACE:-osmo-minimal}"
OSMO_ENDPOINT="${OSMO_ENDPOINT:-}"

IDLE_MINUTES="${IDLE_MINUTES:-20}"
POLL_SECONDS="${POLL_SECONDS:-60}"
ONCE=false
DRY_RUN=false

ENABLE_CPU_RIGHTSIZE=true
CPU_IDLE_DESIRED="${CPU_IDLE_DESIRED:-1}"

GPU_NODEGROUP_REGEX="${GPU_NODEGROUP_REGEX:-gpu|groot}"
CPU_NODEGROUP_REGEX="${CPU_NODEGROUP_REGEX:-nodes}"

API_PAGE_SIZE="${API_PAGE_SIZE:-100}"
API_MAX_PAGES="${API_MAX_PAGES:-20}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-19080}"

STATE_DIR="${STATE_DIR:-/tmp}"
STATE_FILE=""
PF_LOG_FILE="${PF_LOG_FILE:-/tmp/osmo-auto-scale-port-forward.log}"
PORT_FORWARD_PID=""
CURRENT_ENDPOINT=""
ACTIVE_WORKFLOW_COUNT=0

INSTALL_CRON=false
REMOVE_CRON=false
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
CRON_LOG_FILE="${CRON_LOG_FILE:-/tmp/osmo-auto-scale-idle.log}"

log_info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn()    { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --cluster NAME             EKS cluster name (default: detect from kubectl context)
  --region REGION            AWS region (default: detect from context/env)
  --osmo-namespace NS        Namespace with OSMO services (default: osmo-minimal)
  --endpoint URL             Direct OSMO endpoint (skip port-forward), e.g. http://localhost:8080
  --idle-minutes N           Idle timeout before scale-down (default: 20)
  --poll-seconds N           Poll interval for daemon mode (default: 60)
  --once                     Run one check cycle and exit
  --dry-run                  Show intended scaling changes only
  --cpu-desired N            Desired size for CPU nodegroups while idle (default: 1)
  --no-cpu-rightsize         Do not change CPU nodegroups
  --gpu-regex REGEX          Regex for expensive nodegroups (default: gpu|groot)
  --cpu-regex REGEX          Regex for CPU nodegroups (default: nodes)
  --install-cron             Install cron job for --once mode every 5 minutes
  --remove-cron              Remove cron job installed by this script
  --cron-schedule SPEC       Cron schedule for install (default: */5 * * * *)
  -h, --help                 Show this help

Examples:
  $0 --once --cluster osmo --region us-west-2 --idle-minutes 15
  $0 --cluster osmo --region us-west-2 --idle-minutes 15
  $0 --cluster osmo --region us-west-2 --install-cron --idle-minutes 15
EOF
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing required command: $1"
        exit 1
    fi
}

cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
        wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
        PORT_FORWARD_PID=""
    fi
}
trap cleanup EXIT

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster) CLUSTER_NAME="$2"; shift 2 ;;
            --region) AWS_REGION="$2"; shift 2 ;;
            --osmo-namespace) OSMO_NAMESPACE="$2"; shift 2 ;;
            --endpoint) OSMO_ENDPOINT="$2"; shift 2 ;;
            --idle-minutes) IDLE_MINUTES="$2"; shift 2 ;;
            --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
            --once) ONCE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --cpu-desired) CPU_IDLE_DESIRED="$2"; shift 2 ;;
            --no-cpu-rightsize) ENABLE_CPU_RIGHTSIZE=false; shift ;;
            --gpu-regex) GPU_NODEGROUP_REGEX="$2"; shift 2 ;;
            --cpu-regex) CPU_NODEGROUP_REGEX="$2"; shift 2 ;;
            --install-cron) INSTALL_CRON=true; shift ;;
            --remove-cron) REMOVE_CRON=true; shift ;;
            --cron-schedule) CRON_SCHEDULE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

detect_cluster_from_context() {
    local ctx
    ctx="$(kubectl config current-context 2>/dev/null || true)"
    if [[ -z "$ctx" ]]; then
        return 1
    fi

    # Common EKS context format:
    # arn:aws:eks:us-west-2:123456789012:cluster/osmo
    if [[ "$ctx" =~ arn:aws:eks:([^:]+):[0-9]+:cluster/(.+) ]]; then
        if [[ -z "$AWS_REGION" ]]; then
            AWS_REGION="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$CLUSTER_NAME" ]]; then
            CLUSTER_NAME="${BASH_REMATCH[2]}"
        fi
        return 0
    fi

    return 1
}

detect_cluster_and_region() {
    detect_cluster_from_context || true

    if [[ -z "$AWS_REGION" ]]; then
        AWS_REGION="$(aws configure get region 2>/dev/null || true)"
    fi
    if [[ -z "$AWS_REGION" ]]; then
        AWS_REGION="us-west-2"
    fi

    if [[ -z "$CLUSTER_NAME" ]]; then
        CLUSTER_NAME="$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[0]' --output text 2>/dev/null || true)"
        if [[ "$CLUSTER_NAME" == "None" ]]; then
            CLUSTER_NAME=""
        fi
    fi

    if [[ -z "$CLUSTER_NAME" ]]; then
        log_error "Could not determine cluster name. Pass --cluster NAME."
        exit 1
    fi

    STATE_FILE="${STATE_DIR}/osmo-idle-last-active-${CLUSTER_NAME}.epoch"
}

start_port_forward() {
    local svc_name="$1"
    cleanup
    kubectl port-forward "service/${svc_name}" "${PORT_FORWARD_PORT}:80" -n "$OSMO_NAMESPACE" >"$PF_LOG_FILE" 2>&1 &
    PORT_FORWARD_PID=$!

    for _ in {1..20}; do
        if curl -sf "http://localhost:${PORT_FORWARD_PORT}/health" >/dev/null 2>&1; then
            CURRENT_ENDPOINT="http://localhost:${PORT_FORWARD_PORT}"
            return 0
        fi
        if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done

    cleanup
    return 1
}

establish_endpoint() {
    if [[ -n "$OSMO_ENDPOINT" ]]; then
        if curl -sf "${OSMO_ENDPOINT}/health" >/dev/null 2>&1; then
            CURRENT_ENDPOINT="$OSMO_ENDPOINT"
            return 0
        fi
        log_warn "Configured endpoint is not reachable: ${OSMO_ENDPOINT}"
    fi

    if start_port_forward "osmo-proxy"; then
        return 0
    fi
    log_warn "Could not port-forward osmo-proxy; trying osmo-service"

    if start_port_forward "osmo-service"; then
        return 0
    fi

    log_warn "Failed to connect to OSMO API in namespace ${OSMO_NAMESPACE}"
    return 1
}

query_active_workflows() {
    local endpoint="$1"
    local offset=0
    local page=1
    ACTIVE_WORKFLOW_COUNT=0

    while [[ "$page" -le "$API_MAX_PAGES" ]]; do
        local url="${endpoint}/api/workflow?order=DESC&all_users=True&all_pools=True&limit=${API_PAGE_SIZE}&offset=${offset}"
        local response
        if ! response="$(curl -sf -H 'x-osmo-user: testuser' "$url" 2>/dev/null)"; then
            return 2
        fi

        local page_count
        page_count="$(echo "$response" | jq -r '.workflows | length' 2>/dev/null || echo "-1")"
        if ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
            return 2
        fi

        local page_active
        page_active="$(echo "$response" | jq -r '[.workflows[] | select(.status=="RUNNING" or .status=="PENDING" or .status=="WAITING")] | length' 2>/dev/null || echo "-1")"
        if ! [[ "$page_active" =~ ^[0-9]+$ ]]; then
            return 2
        fi

        ACTIVE_WORKFLOW_COUNT=$((ACTIVE_WORKFLOW_COUNT + page_active))
        if [[ "$ACTIVE_WORKFLOW_COUNT" -gt 0 ]]; then
            return 0
        fi

        if [[ "$page_count" -lt "$API_PAGE_SIZE" ]]; then
            return 1
        fi

        offset=$((offset + API_PAGE_SIZE))
        page=$((page + 1))
    done

    log_warn "Workflow scan hit API_MAX_PAGES=${API_MAX_PAGES}; not scaling this cycle for safety."
    return 2
}

has_active_workflows() {
    if ! establish_endpoint; then
        return 2
    fi

    local rc=2
    if query_active_workflows "$CURRENT_ENDPOINT"; then
        rc=0
    else
        local query_rc=$?
        if [[ "$query_rc" -eq 1 ]]; then
            rc=1
        else
            rc=2
        fi
    fi

    cleanup
    return "$rc"
}

record_activity_now() {
    date +%s >"$STATE_FILE"
}

idle_seconds() {
    local now
    now="$(date +%s)"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$now" >"$STATE_FILE"
        echo "0"
        return
    fi

    local last
    last="$(cat "$STATE_FILE" 2>/dev/null || echo "$now")"
    if ! [[ "$last" =~ ^[0-9]+$ ]]; then
        last="$now"
    fi
    if [[ "$last" -gt "$now" ]]; then
        last="$now"
    fi

    echo $((now - last))
}

is_gpu_nodegroup() {
    local ng="$1"
    [[ "$ng" =~ $GPU_NODEGROUP_REGEX ]]
}

is_cpu_nodegroup() {
    local ng="$1"
    [[ "$ng" =~ $CPU_NODEGROUP_REGEX ]] && ! is_gpu_nodegroup "$ng"
}

update_desired_size() {
    local nodegroup="$1"
    local target_desired="$2"
    local reason="$3"

    local scaling
    if ! scaling="$(aws eks describe-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$nodegroup" \
        --region "$AWS_REGION" \
        --query 'nodegroup.scalingConfig' \
        --output json 2>/dev/null)"; then
        log_warn "Could not read scaling config for nodegroup ${nodegroup}"
        return
    fi

    local min_size max_size current_desired
    min_size="$(echo "$scaling" | jq -r '.minSize')"
    max_size="$(echo "$scaling" | jq -r '.maxSize')"
    current_desired="$(echo "$scaling" | jq -r '.desiredSize')"

    if [[ "$target_desired" -lt "$min_size" ]]; then
        log_warn "Skipping ${nodegroup}: target desired ${target_desired} < minSize ${min_size}"
        return
    fi

    if [[ "$current_desired" -eq "$target_desired" ]]; then
        log_info "${nodegroup}: desired already ${current_desired} (${reason})"
        return
    fi

    log_info "${nodegroup}: desired ${current_desired} -> ${target_desired} (${reason})"
    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    if aws eks update-nodegroup-config \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$nodegroup" \
        --region "$AWS_REGION" \
        --scaling-config "minSize=${min_size},maxSize=${max_size},desiredSize=${target_desired}" \
        >/dev/null 2>&1; then
        log_success "Submitted scale update for ${nodegroup}"
    else
        log_warn "Failed to update ${nodegroup} (possibly another update already in progress)"
    fi
}

apply_idle_scaling() {
    local nodegroups_json
    if ! nodegroups_json="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups' --output json 2>/dev/null)"; then
        log_warn "Could not list nodegroups for cluster ${CLUSTER_NAME}"
        return
    fi

    mapfile -t nodegroups < <(echo "$nodegroups_json" | jq -r '.[]')
    if [[ "${#nodegroups[@]}" -eq 0 ]]; then
        log_warn "No nodegroups found for cluster ${CLUSTER_NAME}"
        return
    fi

    for ng in "${nodegroups[@]}"; do
        if is_gpu_nodegroup "$ng"; then
            update_desired_size "$ng" 0 "idle timeout reached"
            continue
        fi

        if [[ "$ENABLE_CPU_RIGHTSIZE" == true ]] && is_cpu_nodegroup "$ng"; then
            update_desired_size "$ng" "$CPU_IDLE_DESIRED" "idle CPU baseline"
        fi
    done
}

run_cycle() {
    local idle_threshold_seconds=$((IDLE_MINUTES * 60))

    if has_active_workflows; then
        record_activity_now
        log_info "Active workflows detected (${ACTIVE_WORKFLOW_COUNT}); keeping current capacity."
        return
    fi

    local activity_rc=$?
    if [[ "$activity_rc" -eq 2 ]]; then
        log_warn "Could not determine workflow activity; skipping scaling changes this cycle."
        return
    fi

    local elapsed_idle
    elapsed_idle="$(idle_seconds)"

    if [[ "$elapsed_idle" -lt "$idle_threshold_seconds" ]]; then
        local remain=$((idle_threshold_seconds - elapsed_idle))
        log_info "No active workflows. Idle ${elapsed_idle}s; scale-down in ${remain}s."
        return
    fi

    log_info "No active workflows for ${elapsed_idle}s (threshold ${idle_threshold_seconds}s); applying idle scaling."
    apply_idle_scaling
}

cron_tag() {
    echo "# OSMO_AUTO_SCALE_IDLE:${CLUSTER_NAME}"
}

install_cron_job() {
    check_command crontab

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local tag
    tag="$(cron_tag)"

    local cmd
    cmd="${script_path} --once --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --osmo-namespace ${OSMO_NAMESPACE} --idle-minutes ${IDLE_MINUTES} --cpu-desired ${CPU_IDLE_DESIRED}"
    if [[ -n "$OSMO_ENDPOINT" ]]; then
        cmd="${cmd} --endpoint ${OSMO_ENDPOINT}"
    fi
    if [[ "$ENABLE_CPU_RIGHTSIZE" == false ]]; then
        cmd="${cmd} --no-cpu-rightsize"
    fi

    local entry="${CRON_SCHEDULE} ${cmd} >> ${CRON_LOG_FILE} 2>&1 ${tag}"

    {
        crontab -l 2>/dev/null | grep -Fv "$tag" || true
        echo "$entry"
    } | crontab -

    log_success "Installed cron job: ${CRON_SCHEDULE}"
    log_info "Log file: ${CRON_LOG_FILE}"
}

remove_cron_job() {
    check_command crontab

    local tag
    tag="$(cron_tag)"

    {
        crontab -l 2>/dev/null | grep -Fv "$tag" || true
    } | crontab -

    log_success "Removed cron job for cluster ${CLUSTER_NAME}"
}

main() {
    parse_args "$@"

    check_command aws
    check_command kubectl
    check_command jq
    check_command curl

    detect_cluster_and_region

    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "Region: ${AWS_REGION}"
    log_info "OSMO namespace: ${OSMO_NAMESPACE}"
    log_info "Idle timeout: ${IDLE_MINUTES} minutes"

    if [[ "$INSTALL_CRON" == true && "$REMOVE_CRON" == true ]]; then
        log_error "Use only one of --install-cron or --remove-cron"
        exit 1
    fi

    if [[ "$INSTALL_CRON" == true ]]; then
        install_cron_job
        exit 0
    fi
    if [[ "$REMOVE_CRON" == true ]]; then
        remove_cron_job
        exit 0
    fi

    if [[ "$ONCE" == true ]]; then
        run_cycle
        exit 0
    fi

    log_info "Starting daemon mode (poll every ${POLL_SECONDS}s)"
    while true; do
        run_cycle
        sleep "$POLL_SECONDS"
    done
}

main "$@"
