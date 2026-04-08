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

import types
import unittest

from src.utils.job import aws_batch


def _sample_aws_config():
    """Creates a config object matching AwsBatchConfig's interface without heavy imports."""
    return types.SimpleNamespace(
        region='us-east-1',
        job_queue_arn='arn:aws:batch:us-east-1:123456789:job-queue/osmo-queue',
        compute_environment_name='osmo-batch-ce',
        execution_role_arn='arn:aws:iam::123456789:role/batch-execution',
    )


def _sample_pod_spec():
    return {
        'kind': 'Pod',
        'apiVersion': 'v1',
        'metadata': {
            'name': 'abc12345-def67890',
            'labels': {
                'osmo.task_uuid': 'task-uuid-123',
                'osmo.workflow_uuid': 'wf-uuid-456',
                'osmo.task_name': 'train',
                'osmo.priority': 'normal',
            },
            'annotations': {
                'osmo.scheduler/type': 'aws_batch',
                'osmo.scheduler/group': 'group-uuid-789',
            },
            'finalizers': ['osmo.nvidia.com/cleanup'],
        },
        'spec': {
            'serviceAccountName': 'osmo-sa',
            'initContainers': [
                {
                    'name': 'osmo-init',
                    'image': 'nvcr.io/osmo/init:latest',
                    'command': ['osmo_init'],
                    'args': ['--data_location', '/osmo/data'],
                    'imagePullPolicy': 'Always',
                    'volumeMounts': [
                        {'name': 'osmo', 'mountPath': '/osmo_binaries'},
                        {'name': 'osmo-data', 'mountPath': '/osmo/data'},
                    ],
                    'resources': {
                        'requests': {'cpu': '250m', 'ephemeral-storage': '1Gi'},
                        'limits': {'cpu': '500m', 'ephemeral-storage': '1Gi'},
                    },
                }
            ],
            'containers': [
                {
                    'name': 'osmo-ctrl',
                    'image': 'nvcr.io/osmo/ctrl:latest',
                    'command': ['osmo_ctrl'],
                    'volumeMounts': [
                        {'name': 'osmo', 'mountPath': '/osmo_binaries'},
                    ],
                    'resources': {
                        'requests': {'cpu': '500m', 'memory': '1Gi'},
                        'limits': {'cpu': '1', 'memory': '2Gi'},
                    },
                },
                {
                    'name': 'user-container',
                    'image': 'user/training:v1',
                    'command': ['python', 'train.py'],
                    'env': [
                        {'name': 'OSMO_DATA', 'value': '/osmo/data'},
                    ],
                    'volumeMounts': [
                        {'name': 'osmo-data', 'mountPath': '/osmo/data'},
                    ],
                    'resources': {
                        'requests': {
                            'cpu': '8', 'memory': '64Gi',
                            'nvidia.com/gpu': '4',
                        },
                        'limits': {
                            'cpu': '8', 'memory': '64Gi',
                            'nvidia.com/gpu': '4',
                        },
                    },
                },
            ],
            'volumes': [
                {'name': 'osmo', 'emptyDir': {}},
                {'name': 'osmo-data', 'emptyDir': {'sizeLimit': '100Gi'}},
                {'name': 'creds', 'secret': {'secretName': 'group-uid-creds'}},
            ],
            'nodeSelector': {'nvidia.com/gpu.product': 'A100'},
            'tolerations': [
                {'key': 'nvidia.com/gpu', 'operator': 'Exists', 'effect': 'NoSchedule'},
            ],
        },
    }


class TestTranslatePodToBatchJobDefinition(unittest.TestCase):

    def test_basic_structure(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')

        self.assertEqual(result['jobDefinitionName'], 'osmo-abc12345-def67890')
        self.assertEqual(result['type'], 'container')
        self.assertIn('eksProperties', result)
        self.assertIn('podProperties', result['eksProperties'])

    def test_labels_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        labels = pod_props['metadata']['labels']
        self.assertEqual(labels['osmo.task_uuid'], 'task-uuid-123')
        self.assertEqual(labels['osmo.workflow_uuid'], 'wf-uuid-456')

    def test_annotations_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        annotations = pod_props['metadata']['annotations']
        self.assertEqual(annotations['osmo.scheduler/type'], 'aws_batch')

    def test_init_containers_translated(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        self.assertIn('initContainers', pod_props)
        init_containers = pod_props['initContainers']
        self.assertEqual(len(init_containers), 1)
        self.assertEqual(init_containers[0]['name'], 'osmo-init')
        self.assertEqual(init_containers[0]['image'], 'nvcr.io/osmo/init:latest')
        self.assertEqual(init_containers[0]['command'], ['osmo_init'])

    def test_containers_translated(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        containers = pod_props['containers']
        self.assertEqual(len(containers), 2)
        self.assertEqual(containers[0]['name'], 'osmo-ctrl')
        self.assertEqual(containers[1]['name'], 'user-container')

    def test_gpu_resources_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        user_container = pod_props['containers'][1]
        self.assertEqual(user_container['resources']['requests']['nvidia.com/gpu'], '4')
        self.assertEqual(user_container['resources']['limits']['nvidia.com/gpu'], '4')

    def test_resource_conversion_cpu_millis(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        ctrl_container = pod_props['containers'][0]
        self.assertEqual(ctrl_container['resources']['requests']['cpu'], '0.5')
        self.assertEqual(ctrl_container['resources']['limits']['cpu'], '1')

    def test_resource_conversion_memory_gi_to_mi(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        ctrl_container = pod_props['containers'][0]
        # Memory request is set to limits value (Batch requires request == limit)
        self.assertEqual(ctrl_container['resources']['requests']['memory'], '2048Mi')
        self.assertEqual(ctrl_container['resources']['limits']['memory'], '2048Mi')

    def test_resource_conversion_memory_request_equals_limit(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        user_container = pod_props['containers'][1]
        self.assertEqual(
            user_container['resources']['requests']['memory'],
            user_container['resources']['limits']['memory'])

    def test_volumes_translated(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        volumes = pod_props['volumes']
        self.assertEqual(len(volumes), 3)
        volume_names = [v['name'] for v in volumes]
        self.assertIn('osmo', volume_names)
        self.assertIn('osmo-data', volume_names)
        self.assertIn('creds', volume_names)

        creds_vol = next(v for v in volumes if v['name'] == 'creds')
        self.assertEqual(creds_vol['secret']['secretName'], 'group-uid-creds')

    def test_node_selector_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        self.assertEqual(
            pod_props['nodeSelector'], {'nvidia.com/gpu.product': 'A100'})

    def test_tolerations_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        self.assertEqual(len(pod_props['tolerations']), 1)
        self.assertEqual(pod_props['tolerations'][0]['key'], 'nvidia.com/gpu')

    def test_service_account_name(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        self.assertEqual(pod_props['serviceAccountName'], 'osmo-sa')

    def test_env_vars_preserved(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        user_container = pod_props['containers'][1]
        self.assertEqual(user_container['env'], [{'name': 'OSMO_DATA', 'value': '/osmo/data'}])

    def test_no_init_containers(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        del pod['spec']['initContainers']
        result = aws_batch.translate_pod_to_batch_job_definition(pod, config, 'osmo-ns')
        pod_props = result['eksProperties']['podProperties']

        self.assertNotIn('initContainers', pod_props)


class TestBuildSubmitJobParams(unittest.TestCase):

    def test_basic_params(self):
        config = _sample_aws_config()
        pod = _sample_pod_spec()
        params = aws_batch.build_submit_job_params(
            'arn:aws:batch:us-east-1:123:job-definition/osmo-test:1',
            pod, config)

        self.assertEqual(params['jobName'], 'abc12345-def67890')
        self.assertEqual(params['jobQueue'], config.job_queue_arn)
        self.assertEqual(
            params['jobDefinition'],
            'arn:aws:batch:us-east-1:123:job-definition/osmo-test:1')


class TestTranslateContainers(unittest.TestCase):

    def test_empty_containers(self):
        result = aws_batch._translate_containers([])
        self.assertEqual(result, [])

    def test_minimal_container(self):
        containers = [{'name': 'test', 'image': 'test:latest'}]
        result = aws_batch._translate_containers(containers)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['name'], 'test')
        self.assertEqual(result[0]['image'], 'test:latest')
        self.assertNotIn('command', result[0])
        self.assertNotIn('env', result[0])


class TestTranslateVolumes(unittest.TestCase):

    def test_empty_dir_volume(self):
        volumes = [{'name': 'data', 'emptyDir': {}}]
        result = aws_batch._translate_volumes(volumes)
        self.assertEqual(result, [{'name': 'data', 'emptyDir': {}}])

    def test_host_path_volume(self):
        volumes = [{'name': 'host', 'hostPath': {'path': '/opt/data'}}]
        result = aws_batch._translate_volumes(volumes)
        self.assertEqual(result[0]['hostPath']['path'], '/opt/data')

    def test_secret_volume(self):
        volumes = [{'name': 'cred', 'secret': {'secretName': 'my-secret'}}]
        result = aws_batch._translate_volumes(volumes)
        self.assertEqual(result[0]['secret']['secretName'], 'my-secret')

    def test_config_map_volume(self):
        volumes = [{'name': 'cfg', 'configMap': {'name': 'my-config'}}]
        result = aws_batch._translate_volumes(volumes)
        self.assertEqual(result[0]['configMap']['name'], 'my-config')


class TestResourceConversion(unittest.TestCase):

    def test_convert_cpu_millis(self):
        self.assertEqual(aws_batch._convert_cpu('250m'), '0.25')
        self.assertEqual(aws_batch._convert_cpu('500m'), '0.5')
        self.assertEqual(aws_batch._convert_cpu('1000m'), '1.0')

    def test_convert_cpu_decimal(self):
        self.assertEqual(aws_batch._convert_cpu('1'), '1')
        self.assertEqual(aws_batch._convert_cpu('0.5'), '0.5')

    def test_convert_memory_mi(self):
        self.assertEqual(aws_batch._convert_memory('512Mi'), '512Mi')
        self.assertEqual(aws_batch._convert_memory('2048Mi'), '2048Mi')

    def test_convert_memory_gi(self):
        self.assertEqual(aws_batch._convert_memory('1Gi'), '1024Mi')
        self.assertEqual(aws_batch._convert_memory('2Gi'), '2048Mi')
        self.assertEqual(aws_batch._convert_memory('64Gi'), '65536Mi')

    def test_convert_memory_ki(self):
        self.assertEqual(aws_batch._convert_memory('1048576Ki'), '1024Mi')

    def test_convert_memory_plain_number(self):
        self.assertEqual(aws_batch._convert_memory('1024'), '1024Mi')


if __name__ == '__main__':
    unittest.main()
