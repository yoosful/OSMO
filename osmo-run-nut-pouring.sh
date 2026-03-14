#!/usr/bin/env bash
#
# Submit the six-step nut-pouring cookbook sequence aligned with the
# 2026-02-25 reproduction report.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COOKBOOK_DIR="${REPO_ROOT}/cookbook/nut_pouring"
POOL_NAME="${POOL_NAME:-default}"
INPUT_HDF5="${INPUT_HDF5:-}"
INPUT_DATASET_NAME="${INPUT_DATASET_NAME:-PhysAI-InputMimic}"
SKIP_UPLOAD=false
MAX_STEPS="${MAX_STEPS:-1}"
RUN_METADATA_PATH="${RUN_METADATA_PATH:-}"

log_info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --pool NAME          OSMO pool name (default: default)
  --input-hdf5 PATH    Local nut-pouring teleop HDF5 to upload for Step 1
  --input-dataset NAME Input dataset name for Step 1 (default: PhysAI-InputMimic)
  --skip-upload        Assume the input dataset already exists in OSMO
  --max-steps N        Step 6 GR00T max_steps override (default: 1)
  --run-metadata PATH  Write workflow submission metadata JSON to this path
  -h, --help           Show this help
EOF
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing required command: $1"
        exit 1
    fi
}

json_field() {
    local field_name="$1"
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$field_name"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pool) POOL_NAME="$2"; shift 2 ;;
            --input-hdf5) INPUT_HDF5="$2"; shift 2 ;;
            --input-dataset) INPUT_DATASET_NAME="$2"; shift 2 ;;
            --skip-upload) SKIP_UPLOAD=true; shift ;;
            --max-steps) MAX_STEPS="$2"; shift 2 ;;
            --run-metadata) RUN_METADATA_PATH="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

append_run_metadata() {
    local step_name="$1"
    local workflow_file="$2"
    local workflow_id="$3"
    if [[ -z "$RUN_METADATA_PATH" ]]; then
        return
    fi
    python3 - "$RUN_METADATA_PATH" "$step_name" "$workflow_file" "$workflow_id" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, step_name, workflow_file, workflow_id = sys.argv[1:5]
payload = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
payload.append(
    {
        "step_name": step_name,
        "workflow_file": workflow_file,
        "workflow_id": workflow_id,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
PY
}

upload_input_dataset() {
    if [[ "$SKIP_UPLOAD" == true ]]; then
        log_info "Skipping dataset upload"
        return
    fi

    if [[ -z "$INPUT_HDF5" ]]; then
        log_error "--input-hdf5 is required unless --skip-upload is used"
        exit 1
    fi

    if [[ ! -f "$INPUT_HDF5" ]]; then
        log_error "Input HDF5 not found: $INPUT_HDF5"
        exit 1
    fi

    log_info "Uploading input dataset ${INPUT_DATASET_NAME} from ${INPUT_HDF5}"
    osmo dataset upload "$INPUT_DATASET_NAME" "$INPUT_HDF5"
}

submit_workflow() {
    local workflow_file="$1"
    local step_name="$2"
    shift
    shift
    log_info "Submitting $(basename "$workflow_file")"
    local submit_output
    local workflow_id
    submit_output="$(osmo workflow submit "$workflow_file" --pool "$POOL_NAME" --format-type json "$@")"
    workflow_id="$(printf '%s' "$submit_output" | json_field name)"
    if [[ -z "$workflow_id" ]]; then
        log_error "Failed to extract workflow ID from submission output"
        printf '%s\n' "$submit_output"
        exit 1
    fi
    append_run_metadata "$step_name" "$workflow_file" "$workflow_id"
    wait_for_workflow "$workflow_id"
}

wait_for_workflow() {
    local workflow_id="$1"
    local status=""
    log_info "Waiting for workflow ${workflow_id}"
    while true; do
        status="$(
            osmo workflow query "$workflow_id" --format-type json | json_field status
        )"
        case "$status" in
            COMPLETED)
                log_success "${workflow_id} completed"
                return
                ;;
            FAILED|FAILED_SUBMISSION|FAILED_SERVER_ERROR|FAILED_EXEC_TIMEOUT|FAILED_QUEUE_TIMEOUT|FAILED_PREEMPTED|CANCELLED)
                log_error "${workflow_id} ended with status ${status}"
                exit 1
                ;;
            *)
                sleep 30
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    check_command osmo
    check_command python3

    cat <<'EOF'
Required before running:
  1. osmo login against the target cluster
  2. osmo credential set huggingface_token --type GENERIC --payload token=<hf-token>
  3. Hugging Face gated approvals for Cosmos and GR00T models
EOF

    upload_input_dataset

    submit_workflow "${COOKBOOK_DIR}/01_mimic_generation_v1.yaml" "mimic_generation"
    submit_workflow "${COOKBOOK_DIR}/02_hdf5_to_mp4_v1.yaml" "hdf5_to_mp4"
    submit_workflow "${COOKBOOK_DIR}/03_cosmos_augmentation.yaml" "cosmos_augmentation"
    submit_workflow "${COOKBOOK_DIR}/04_mp4_to_hdf5.yaml" "mp4_to_hdf5"
    submit_workflow "${COOKBOOK_DIR}/05_lerobot_conversion.yaml" "lerobot_conversion"
    submit_workflow "${COOKBOOK_DIR}/06_groot_finetune.yaml" "groot_finetune" --set "max_steps=${MAX_STEPS}"

    log_success "Submitted the full nut-pouring workflow sequence"
}

main "$@"
