"""
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.  # pylint: disable=line-too-long

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
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any, Dict, List

if TYPE_CHECKING:
    from src.utils.connectors.postgres import AwsBatchConfig


def translate_pod_to_batch_job_definition(
    pod_spec: Dict[str, Any],
    aws_config: AwsBatchConfig,
    namespace: str,
) -> Dict[str, Any]:
    """Translates an OSMO K8s pod spec into an AWS Batch RegisterJobDefinition request body.

    AWS Batch on EKS uses eksProperties to define pod-level configuration. This function
    maps OSMO's multi-container pod structure (init + ctrl + user containers) into the
    Batch EKS job definition format.

    Args:
        pod_spec: A standard K8s pod spec dict (kind: Pod, apiVersion: v1).
        aws_config: AWS Batch configuration with queue ARN, execution role, etc.
        namespace: The K8s namespace where pods should be created.

    Returns:
        A dict suitable for boto3 batch.register_job_definition().
    """
    metadata = pod_spec.get('metadata', {})
    spec = pod_spec.get('spec', {})
    pod_name = metadata.get('name', 'osmo-task')
    labels = metadata.get('labels', {})
    annotations = metadata.get('annotations', {})

    containers = _translate_containers(spec.get('containers', []))
    init_containers = _translate_containers(spec.get('initContainers', []))
    volumes = _translate_volumes(spec.get('volumes', []))

    pod_properties: Dict[str, Any] = {
        'serviceAccountName': spec.get('serviceAccountName', 'default'),
        'containers': containers,
        'volumes': volumes,
        'metadata': {
            'labels': labels,
            'annotations': annotations,
        },
    }

    if init_containers:
        pod_properties['initContainers'] = init_containers

    if spec.get('hostNetwork'):
        pod_properties['hostNetwork'] = True

    if spec.get('dnsPolicy'):
        pod_properties['dnsPolicy'] = spec['dnsPolicy']

    node_selector = spec.get('nodeSelector', {})
    if node_selector:
        pod_properties['nodeSelector'] = node_selector

    tolerations = spec.get('tolerations', [])
    if tolerations:
        pod_properties['tolerations'] = tolerations

    job_definition_name = f'osmo-{pod_name}'

    return {
        'jobDefinitionName': job_definition_name,
        'type': 'container',
        'eksProperties': {
            'podProperties': pod_properties,
        },
    }


def build_submit_job_params(
    job_definition_arn: str,
    pod_spec: Dict[str, Any],
    aws_config: AwsBatchConfig,
) -> Dict[str, Any]:
    """Builds the parameters for a boto3 batch.submit_job() call.

    Args:
        job_definition_arn: The ARN of the registered job definition.
        pod_spec: The original K8s pod spec (used to extract the job name).
        aws_config: AWS Batch configuration.

    Returns:
        A dict suitable for boto3 batch.submit_job().
    """
    metadata = pod_spec.get('metadata', {})
    pod_name = metadata.get('name', 'osmo-task')

    return {
        'jobName': pod_name,
        'jobQueue': aws_config.job_queue_arn,
        'jobDefinition': job_definition_arn,
    }


def register_job_definition(batch_client: Any, definition: Dict[str, Any]) -> str:
    """Registers an AWS Batch job definition and returns its ARN.

    Args:
        batch_client: A boto3 Batch client.
        definition: The job definition request body.

    Returns:
        The ARN of the registered job definition.
    """
    response = batch_client.register_job_definition(**definition)
    job_definition_arn = response['jobDefinitionArn']
    logging.info('Registered AWS Batch job definition: %s', job_definition_arn)
    return job_definition_arn


def submit_batch_job(batch_client: Any, job_params: Dict[str, Any]) -> str:
    """Submits a job to AWS Batch and returns the job ID.

    Args:
        batch_client: A boto3 Batch client.
        job_params: The submit_job request parameters.

    Returns:
        The AWS Batch job ID.
    """
    response = batch_client.submit_job(**job_params)
    job_id = response['jobId']
    logging.info('Submitted AWS Batch job: %s (id=%s)', job_params.get('jobName'), job_id)
    return job_id


def cancel_batch_job(batch_client: Any, job_id: str, reason: str = 'OSMO cleanup') -> None:
    """Terminates an AWS Batch job. Idempotent — calling on a finished job is a no-op."""
    try:
        batch_client.terminate_job(jobId=job_id, reason=reason)
        logging.info('Terminated AWS Batch job: %s', job_id)
    except Exception:
        logging.warning('Failed to terminate AWS Batch job: %s', job_id, exc_info=True)


def deregister_job_definition(batch_client: Any, job_definition_arn: str) -> None:
    """Deregisters an AWS Batch job definition during cleanup.

    Args:
        batch_client: A boto3 Batch client.
        job_definition_arn: The ARN of the job definition to deregister.
    """
    try:
        batch_client.deregister_job_definition(jobDefinition=job_definition_arn)
        logging.info('Deregistered AWS Batch job definition: %s', job_definition_arn)
    except Exception:
        logging.warning('Failed to deregister job definition: %s',
                        job_definition_arn, exc_info=True)


def _translate_containers(containers: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Translates K8s container specs to AWS Batch EKS container format.

    AWS Batch EKS container format is very close to the K8s container spec but uses
    a slightly different structure for resources.
    """
    result = []
    for container in containers:
        translated: Dict[str, Any] = {
            'name': container.get('name', ''),
            'image': container.get('image', ''),
        }

        if 'command' in container:
            translated['command'] = container['command']
        if 'args' in container:
            translated['args'] = container['args']
        if 'env' in container:
            translated['env'] = container['env']
        if 'volumeMounts' in container:
            translated['volumeMounts'] = container['volumeMounts']
        if 'imagePullPolicy' in container:
            translated['imagePullPolicy'] = container['imagePullPolicy']

        resources = container.get('resources', {})
        if resources:
            translated['resources'] = _translate_resources(resources)

        if 'securityContext' in container:
            translated['securityContext'] = container['securityContext']

        result.append(translated)
    return result


def _translate_resources(resources: Dict[str, Any]) -> Dict[str, Any]:
    """Translates K8s resource requests/limits to AWS Batch EKS format.

    AWS Batch EKS requires:
    - cpu: vCPUs as decimal string (e.g., "0.25" not "250m")
    - memory: MiB with Mi suffix (e.g., "512Mi" not "1Gi")
    - nvidia.com/gpu: count as string (e.g., "1")
    - memory request must equal memory limit when both are provided

    To satisfy the memory constraint, when both requests and limits are present,
    we use the limits value for both.
    """
    requests = _convert_resource_values(resources.get('requests', {}))
    limits = _convert_resource_values(resources.get('limits', {}))

    if 'memory' in limits and 'memory' in requests:
        requests['memory'] = limits['memory']

    translated: Dict[str, Any] = {}
    if requests:
        translated['requests'] = requests
    if limits:
        translated['limits'] = limits
    return translated


def _convert_resource_values(resource_map: Dict[str, Any]) -> Dict[str, str]:
    """Converts K8s resource notation to AWS Batch numeric strings.

    K8s resource values may be strings ("250m", "1Gi") or ints/floats, so all
    values are coerced to str before conversion.
    """
    result: Dict[str, str] = {}
    for key, value in resource_map.items():
        string_value = str(value)
        if key == 'cpu':
            result[key] = _convert_cpu(string_value)
        elif key == 'memory':
            result[key] = _convert_memory(string_value)
        else:
            result[key] = string_value
    return result


def _convert_cpu(value: str) -> str:
    """Converts K8s CPU notation to decimal vCPU string.

    Examples: "250m" -> "0.25", "1" -> "1", "1.5" -> "1.5"
    """
    if value.endswith('m'):
        return str(int(value[:-1]) / 1000)
    return value


def _convert_memory(value: str) -> str:
    """Converts K8s memory notation to MiB string with Mi suffix for AWS Batch.

    AWS Batch on EKS only accepts the Mi suffix for memory values.

    Examples: "512Mi" -> "512Mi", "1Gi" -> "1024Mi", "1024" -> "1024Mi"
    """
    if value.endswith('Gi'):
        return str(int(float(value[:-2]) * 1024)) + 'Mi'
    if value.endswith('Mi'):
        return value
    if value.endswith('Ki'):
        return str(int(int(value[:-2]) / 1024)) + 'Mi'
    if value.endswith('Ti'):
        return str(int(float(value[:-2]) * 1024 * 1024)) + 'Mi'
    return value + 'Mi'


def _translate_volumes(volumes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Translates K8s volume specs to AWS Batch EKS format.

    AWS Batch on EKS supports emptyDir, hostPath, and secret volumes.
    """
    result = []
    for volume in volumes:
        translated: Dict[str, Any] = {'name': volume.get('name', '')}

        if 'emptyDir' in volume:
            translated['emptyDir'] = volume['emptyDir']
        elif 'hostPath' in volume:
            translated['hostPath'] = volume['hostPath']
        elif 'secret' in volume:
            translated['secret'] = volume['secret']
        elif 'configMap' in volume:
            translated['configMap'] = volume['configMap']

        result.append(translated)
    return result
