..
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.  # pylint: disable=line-too-long

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

.. _fsx_lustre_dataset_inputs:

==================================
FSx Lustre Dataset I/O
==================================

OSMO can expose S3-backed dataset inputs, outputs, and updates through an
existing Amazon FSx for Lustre mount. For inputs, OSMO still downloads the
dataset manifest from S3 as the source of truth, but each manifest object is
symlinked from the configured FSx for Lustre path into ``{{input:<index>}}``
before the user command starts.

For dataset outputs and updates, user code still writes to the normal
``{{output}}`` path. During output finalization, ``osmo-ctrl`` writes the
content-addressed dataset objects and manifest into the configured FSx for
Lustre path, waits until those S3 objects are visible through the Data Repository
Association, and only then completes the dataset version.

This integration is intentionally narrow: OSMO does not create FSx file systems,
Data Repository Associations, CSI drivers, PVs, PVCs, or Kubernetes mounts. The
cluster admin provides those resources through the backend cluster and pod
templates.

When to Use It
==============

Use ``fsx-lustre`` when all of these are true:

- The dataset bucket ``dataset_path`` is an ``s3://`` URI.
- An FSx for Lustre Data Repository Association mirrors the same S3 bucket or prefix.
- Workflow pods mount the FSx PVC at a stable path in both ``osmo-ctrl`` and the
  user container for inputs.
- ``osmo-ctrl`` has a writable FSx mount if dataset outputs or updates should
  be written through FSx.
- Fast failure is preferred when FSx metadata or files are stale, instead of falling back to S3 download.

This mode only affects OSMO dataset I/O for S3-backed dataset buckets that have
``fsx_lustre`` configured. URL inputs, task inputs, URL outputs, task outputs,
and KPI outputs continue to use the existing OSMO paths.

Admin Setup
===========

1. Create or reuse an FSx for Lustre file system with an S3 Data Repository
   Association for the same bucket or prefix used by the OSMO dataset bucket.
   Import metadata and enable automatic import if new S3 objects should appear
   in FSx without manual refresh. Enable automatic export if dataset outputs or
   updates should be written through FSx.

2. Install the AWS FSx CSI driver on the backend EKS cluster, create a PV/PVC,
   and verify a test pod can read and, when output/update support is enabled,
   write files under the mounted FSx path.

3. Configure the OSMO dataset bucket with ``fsx_lustre.mount_path``. The mount
   path must be the local FSx directory that corresponds exactly to the bucket's
   ``dataset_path`` prefix.

4. Add a pod template that mounts the PVC into both ``osmo-ctrl`` and
   ``{{USER_CONTAINER_NAME}}``. For input-only pools the mount can be read-only.
   For dataset outputs or updates, ``osmo-ctrl`` must mount it writable. Attach
   that template to the pool or platform used by the workflow.

Example Configuration
=====================

.. include:: ../_shared/configmap_banner.rst

The example below assumes:

- The OSMO dataset bucket prefix is ``s3://my-datasets/osmo``.
- The backend cluster mounts the FSx file system at ``/mnt/osmo-fsx``.
- The local FSx path ``/mnt/osmo-fsx/osmo`` corresponds to
  ``s3://my-datasets/osmo``.

.. code-block:: yaml

   services:
     configs:
       dataset:
         default_bucket: training
         buckets:
           training:
             dataset_path: s3://my-datasets/osmo
             region: us-west-2
             fsx_lustre:
               mount_path: /mnt/osmo-fsx/osmo

       pools:
         training:
           name: training
           backend: eks-backend
           download_type: fsx-lustre
           common_pod_template:
             - fsx_lustre_mount
           platforms:
             default:
               name: default

       podTemplates:
         fsx_lustre_mount:
           spec:
             volumes:
               - name: fsx-lustre
                 persistentVolumeClaim:
                   claimName: osmo-fsx-lustre
             containers:
               - name: osmo-ctrl
                 volumeMounts:
                   - name: fsx-lustre
                     mountPath: /mnt/osmo-fsx
                     readOnly: false
               - name: "{{USER_CONTAINER_NAME}}"
                 volumeMounts:
                   - name: fsx-lustre
                     mountPath: /mnt/osmo-fsx
                     readOnly: true

Users can also set ``downloadType: fsx-lustre`` on a workflow or task. The usual
inheritance still applies: task value, then pool ``download_type``, then workflow
``workflow_data.download_type``.

Validation Behavior
===================

OSMO validates FSx for Lustre configuration in two phases:

- At config load time, ``fsx_lustre`` is allowed only for ``s3://`` dataset
  buckets and ``mount_path`` must be absolute.
- At pod generation time, every S3-backed dataset input, output, or update in
  an ``fsx-lustre`` task must have bucket ``fsx_lustre.mount_path``. Dataset
  inputs require the generated pod to mount that path in both ``osmo-ctrl`` and
  the user container after pod templates are applied. Dataset outputs and
  updates require ``osmo-ctrl`` to mount the path as writable.

At runtime, ``osmo-ctrl`` downloads the dataset manifest from S3 and resolves
each manifest ``storage_path`` using the longest matching configured S3 prefix.
Each resolved FSx source path must exist before the symlink is created. Missing
FSx files fail the task before the user command starts.

For dataset outputs and updates, ``osmo-ctrl`` writes new content-addressed
objects and the new manifest to FSx for Lustre. OSMO waits for those S3 objects
to become visible before marking the dataset version complete. If FSx automatic
export is not configured or is delayed beyond the timeout, the task fails with a
message that identifies the pending objects.

Operational Checks
==================

Before enabling the pool for users, run these checks:

- Submit a workflow with one S3-backed dataset input and
  ``downloadType: fsx-lustre``. Confirm the task log shows manifest download
  followed by FSx linking, and that user code can read files under
  ``{{input:0}}``.
- Remove the pod template mount and confirm submission fails before a pod is
  created.
- Remove or rename one FSx source object and confirm the task fails before the
  user command starts.
- Submit a workflow with a dataset output or update. Confirm user code writes
  only to ``{{output}}``, task logs show dataset upload/update completion, and a
  downstream normal ``download`` task can read the new dataset version from S3.
- Submit the same workflow with default ``download`` and confirm behavior is
  unchanged.
