<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

SPDX-License-Identifier: Apache-2.0
-->

# Nut Pouring Report Reproduction

This runbook is aligned with `Nut_Pouring_Pipeline_Report.pptx` dated 2026-02-25. It targets the same six-step cookbook flow on AWS/EKS and uses the workflow variants that were tuned for the reported reproduction.

The report tooling in this branch is manifest-driven:

- `generate_nut_pouring_report.py` builds the PPTX from a YAML manifest.
- `collect_nut_pouring_evidence.py` builds an artifact pack with copied sample assets and side-by-side comparisons.
- `report_manifest.example.yaml` is the baseline manifest shape.

## What the report shows

The report captures one successful end-to-end chain:

`PhysAI-InputMimic` -> `PhysAI-MimicGen` -> `PhysAI-MP4Videos` -> `PhysAI-CosmosAugmentedMP4` -> `PhysAI-CosmosAugmentedHDF5` -> `PhysAI-LeRobotDataset` -> `PhysAI-GR00T-Finetuned`

Recorded workflow order:

1. `01_mimic_generation_v1.yaml`
2. `02_hdf5_to_mp4_v1.yaml`
3. `03_cosmos_augmentation.yaml`
4. `04_mp4_to_hdf5.yaml`
5. `05_lerobot_conversion.yaml`
6. `06_groot_finetune.yaml`

## Required prerequisites

- Local tools: `aws`, `kubectl`, `helm`, `terraform`, and Python deps for report generation.
- Bootstrap helper for this branch:

```bash
./bootstrap_aws_repro_tools.sh
export PATH="$HOME/.local/bin:$PATH"
```

- AWS/EKS OSMO cluster with CPU plus GPU capacity
- NGC API key for `nvcr.io` image pulls
- Hugging Face token configured in OSMO:

```bash
osmo credential set huggingface_token --type GENERIC --payload token=<your-hf-token>
```

- Gated approvals granted for the Cosmos and GR00T model repos
- Initial teleoperation HDF5:

```bash
curl -O https://download.isaacsim.omniverse.nvidia.com/isaaclab/dataset/dataset_annotated_gr1_nut_pouring.hdf5
```

## Recommended execution path

Deploy OSMO on AWS/EKS:

```bash
NGC_API_KEY=<your-ngc-api-key> ./osmo-deploy.sh
```

Login and run the full sequence:

```bash
osmo login http://localhost:8080 --method=dev --username=testuser
./osmo-run-nut-pouring.sh \
  --pool default \
  --input-hdf5 ./dataset_annotated_gr1_nut_pouring.hdf5 \
  --run-metadata ./nut_pouring_run.json \
  --max-steps 1
```

`--max-steps 1` matches the report's GR00T reproducibility check. Increase only after the baseline six-step run succeeds.

Generate the artifact pack and PPTX:

```bash
python3 collect_nut_pouring_evidence.py \
  --manifest cookbook/nut_pouring/report_manifest.example.yaml \
  --output-dir ./nut_pouring_artifacts

python3 generate_nut_pouring_report.py \
  --manifest cookbook/nut_pouring/report_manifest.example.yaml \
  --output ./Nut_Pouring_Pipeline_Report.pptx
```

## Report-specific checks

- Step 3 must preserve the generated `demo_*_robot_pov_cam.mp4` outputs.
- Step 4 must use the nut-pouring schema-aware MP4-to-HDF5 conversion.
- Step 5 should export a `nut_pouring_task/lerobot` tree.
- Step 6 should finish with checkpoint artifacts in `PhysAI-GR00T-Finetuned`.

## Common failure modes from the report

- Missing gated Hugging Face approvals blocks Steps 3 and 6.
- Selecting the wrong Step 3 artifact breaks Step 4 input expectations.
- Trying full-scale GR00T training before a `max_steps=1` proof run increases cost and failure surface.
- Leaving GPU nodegroups running after the workflows finish wastes cost; use `deployments/scripts/aws/auto-scale-idle.sh`.
