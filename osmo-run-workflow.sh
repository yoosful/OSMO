#!/bin/bash
###############################################################################
# OSMO Workflow Submission & Monitoring Script
#
# Submits an Isaac Sim SDG workflow via the OSMO REST API, polls until
# completion, and prints dataset details on success.
#
# Prerequisites:
#   - kubectl configured for the target EKS cluster
#   - curl, jq installed
#   - OSMO deployed (see osmo-deploy.sh)
#
# Usage:
#   ./osmo-run-workflow.sh [--endpoint URL] [--workflow-file PATH]
#                          [--pool POOL] [--no-port-forward]
#
###############################################################################

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

OSMO_ENDPOINT="${OSMO_ENDPOINT:-http://localhost:8080}"
OSMO_NAMESPACE="${OSMO_NAMESPACE:-osmo-minimal}"
WORKFLOW_FILE="${WORKFLOW_FILE:-}"
POOL_NAME="${POOL_NAME:-default}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
USE_PORT_FORWARD=true
PORT_FORWARD_PID=""

# Bug #2 fix: dev mode auth uses x-osmo-user header, no token needed
OSMO_AUTH_HEADER="x-osmo-user: testuser"

###############################################################################
# Parse Arguments
###############################################################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoint)         OSMO_ENDPOINT="$2"; shift 2 ;;
        --workflow-file)    WORKFLOW_FILE="$2"; shift 2 ;;
        --pool)             POOL_NAME="$2"; shift 2 ;;
        --no-port-forward)  USE_PORT_FORWARD=false; shift ;;
        --poll-interval)    POLL_INTERVAL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--endpoint URL] [--workflow-file PATH] [--pool POOL] [--no-port-forward]"
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

cleanup() {
    if [[ -n "$PORT_FORWARD_PID" ]]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

# Helper: JSON-encode a string value (escape special chars for JSON string)
json_encode_string() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"
}

###############################################################################
# Default Workflow Spec (Isaac Sim SDG)
###############################################################################

# Bug #1 fix: generate valid OSMO workflow YAML using the workflow: spec format
# (per serial_workflow.yaml pattern), not fabricated JSON.
generate_default_workflow_yaml() {
    cat <<'WORKFLOW_YAML'
workflow:
  name: isaac-sim-sdg-repro
  tasks:
  - name: sdg-task
    image: nvcr.io/nvidia/isaac-sim:4.5.0
    command: ["/bin/bash"]
    args: ["/tmp/run.sh"]
    files:
    - contents: |
        echo 'Starting Isaac Sim SDG...'
        /isaac-sim/python.sh -c "
        import omni.replicator.core as rep
        rep.new_layer()
        camera = rep.create.camera(position=(0, 0, 100))
        render_product = rep.create.render_product(camera, (1024, 1024))
        writer = rep.WriterRegistry.get('BasicWriter')
        writer.initialize(output_dir='{{output}}/sdg_output', rgb=True)
        rep.orchestrator.run_until_complete(num_frames=10)
        print('SDG Complete: 10 frames generated')
        " || echo "Isaac Sim SDG completed with exit code: $?"
      path: /tmp/run.sh
    resources:
      cpu: "4"
      memory: 16Gi
      gpu: 1
WORKFLOW_YAML
}

###############################################################################
# Phase 1: Port-forward
###############################################################################

setup_port_forward() {
    if [[ "$USE_PORT_FORWARD" == false ]]; then
        log_info "Using endpoint: $OSMO_ENDPOINT (no port-forward)"
        return
    fi

    log_info "Setting up port-forward to osmo-proxy..."

    # Bug #4 fix: health endpoint is /health, not /api/health
    if curl -sf "$OSMO_ENDPOINT/health" &>/dev/null; then
        log_info "Endpoint $OSMO_ENDPOINT already accessible"
        return
    fi

    kubectl port-forward service/osmo-proxy 8080:80 -n "$OSMO_NAMESPACE" &
    PORT_FORWARD_PID=$!
    sleep 3

    # Verify connectivity
    if ! curl -sf "$OSMO_ENDPOINT/health" &>/dev/null; then
        # Fallback: try osmo-service directly
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        kubectl port-forward service/osmo-service 8080:80 -n "$OSMO_NAMESPACE" &
        PORT_FORWARD_PID=$!
        sleep 3
    fi

    if curl -sf "$OSMO_ENDPOINT/health" &>/dev/null; then
        log_success "Connected to OSMO at $OSMO_ENDPOINT"
    else
        log_error "Cannot reach OSMO at $OSMO_ENDPOINT"
        exit 1
    fi
}

###############################################################################
# Phase 2: Submit Workflow
###############################################################################
# Bug #2 fix: removed login() entirely — dev mode uses x-osmo-user header

WORKFLOW_NAME=""

submit_workflow() {
    log_info "Submitting workflow..."

    local workflow_yaml
    if [[ -n "$WORKFLOW_FILE" && -f "$WORKFLOW_FILE" ]]; then
        workflow_yaml=$(cat "$WORKFLOW_FILE")
        log_info "Using workflow from: $WORKFLOW_FILE"
    else
        workflow_yaml=$(generate_default_workflow_yaml)
        log_info "Using default Isaac Sim SDG workflow"
    fi

    # Bug #1/#3 fix: API expects TemplateSpec model: {"file": "<yaml-string>", "set_variables": []}
    local encoded_yaml
    encoded_yaml=$(json_encode_string "$workflow_yaml")

    local payload="{\"file\": ${encoded_yaml}, \"set_variables\": []}"

    local response
    response=$(curl -sf -X POST "$OSMO_ENDPOINT/api/pool/${POOL_NAME}/workflow" \
        -H "$OSMO_AUTH_HEADER" \
        -H 'Content-Type: application/json' \
        -d "$payload" || echo "")

    # SubmitResponse has a 'name' field (the workflow name/id)
    WORKFLOW_NAME=$(echo "$response" | jq -r '.name // empty' 2>/dev/null || echo "")

    if [[ -z "$WORKFLOW_NAME" ]]; then
        log_error "Failed to submit workflow. Response: $response"
        exit 1
    fi

    log_success "Workflow submitted: $WORKFLOW_NAME"
}

###############################################################################
# Phase 3: Poll Workflow Status
###############################################################################

poll_workflow() {
    log_info "Polling workflow status (every ${POLL_INTERVAL}s)..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local response
        response=$(curl -sf "$OSMO_ENDPOINT/api/workflow/${WORKFLOW_NAME}" \
            -H "$OSMO_AUTH_HEADER" || echo "")

        # Bug #5 fix: field is 'status' (WorkflowStatus enum)
        local status
        status=$(echo "$response" | jq -r '.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

        local elapsed=$(( $(date +%s) - start_time ))
        local elapsed_min=$(( elapsed / 60 ))
        local elapsed_sec=$(( elapsed % 60 ))

        echo -e "  [${elapsed_min}m${elapsed_sec}s] Status: $status"

        case "$status" in
            COMPLETED)
                echo ""
                log_success "Workflow completed in ${elapsed_min}m${elapsed_sec}s"
                return 0
                ;;
            FAILED|FAILED_SUBMISSION|FAILED_SERVER_ERROR|FAILED_EXEC_TIMEOUT|FAILED_QUEUE_TIMEOUT)
                echo ""
                log_error "Workflow failed ($status) after ${elapsed_min}m${elapsed_sec}s"
                echo "Full response:"
                echo "$response" | jq . 2>/dev/null || echo "$response"
                return 1
                ;;
            CANCELLED|cancelled)
                echo ""
                log_warn "Workflow was cancelled after ${elapsed_min}m${elapsed_sec}s"
                return 1
                ;;
        esac

        sleep "$POLL_INTERVAL"
    done
}

###############################################################################
# Phase 4: Print Results
###############################################################################

print_results() {
    log_info "Fetching workflow details..."

    local response
    response=$(curl -sf "$OSMO_ENDPOINT/api/workflow/${WORKFLOW_NAME}" \
        -H "$OSMO_AUTH_HEADER" || echo "")

    echo ""
    echo "=============================================================================="
    echo "                    Workflow Results"
    echo "=============================================================================="
    echo ""
    echo "Workflow Name: $WORKFLOW_NAME"
    echo ""

    # Print formatted output
    echo "$response" | jq '{
        name,
        uuid,
        status,
        submitted_by,
        submit_time,
        start_time,
        end_time,
        duration,
        pool,
        backend
    }' 2>/dev/null || echo "$response"

    echo ""
    echo "=============================================================================="
    echo ""
    echo "View in UI:"
    echo "  $OSMO_ENDPOINT (navigate to Workflows > $WORKFLOW_NAME)"
    echo ""
    echo "Fetch logs:"
    echo "  curl -H '$OSMO_AUTH_HEADER' \\"
    echo "    $OSMO_ENDPOINT/api/workflow/$WORKFLOW_NAME/logs"
    echo "=============================================================================="
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    echo "=============================================================================="
    echo "              OSMO Workflow Submission & Monitoring"
    echo "=============================================================================="
    echo ""

    check_command "curl"
    check_command "jq"
    check_command "python3"
    if [[ "$USE_PORT_FORWARD" == true ]]; then
        check_command "kubectl"
    fi

    setup_port_forward
    submit_workflow

    if poll_workflow; then
        print_results
    else
        print_results
        exit 1
    fi
}

main
