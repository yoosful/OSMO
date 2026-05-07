# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for FSx Lustre dataset write helpers."""

import json
import hashlib
import os
import pathlib
import tempfile
import unittest
from unittest import mock

import diskcache

from src.lib.data import storage
from src.lib.data.dataset import common, fsx_lustre, uploading
from src.lib.data.storage.core import executor, progress
from src.lib.utils import common as utils_common


class FSxLustreDatasetWriteTest(unittest.TestCase):
    """Tests for writing dataset objects and manifests through an FSx mount."""

    def test_resolve_path_uses_longest_prefix(self):
        config = fsx_lustre.FSxLustreConfig(mounts=[
            fsx_lustre.FSxLustreMount(
                storage_path='s3://bucket/datasets',
                mount_path='/fsx/root',
            ),
            fsx_lustre.FSxLustreMount(
                storage_path='s3://bucket/datasets/special',
                mount_path='/fsx/special',
            ),
        ])

        self.assertEqual(
            fsx_lustre.resolve_path(
                's3://bucket/datasets/special/hash/file.txt',
                config,
            ),
            os.path.join('/fsx/special', 'hash', 'file.txt'),
        )

    def test_dataset_upload_worker_writes_local_file_to_fsx(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            source = root / 'source.txt'
            source.write_text('fsx-output', encoding='utf-8')
            fsx_root = root / 'fsx'
            config = fsx_lustre.FSxLustreConfig(mounts=[
                fsx_lustre.FSxLustreMount(
                    storage_path='s3://bucket/datasets',
                    mount_path=str(fsx_root),
                ),
            ])
            destination = storage.construct_storage_backend(
                's3://bucket/datasets/dataset-id/hashes',
            )
            manifest_cache = diskcache.Index()
            storage_path_cache = diskcache.Index()
            entry = uploading.UploadLocalFileEntry(
                relative_path='source.txt',
                source=str(source),
                destination=destination,
                destination_region='us-east-1',
                size=source.stat().st_size,
            )

            output = uploading.dataset_upload_worker(
                uploading.DatasetUploadWorkerInput(
                    index=0,
                    entry=entry,
                    manifest_cache=manifest_cache,
                    fsx_lustre_config=config,
                    fsx_lustre_storage_path_cache=storage_path_cache,
                ),
                client_provider=mock.MagicMock(),
                progress_updater=progress.NoOpProgressUpdater(),
            )

            etag = utils_common.etag_checksum(str(source))
            fsx_object = fsx_root / 'dataset-id' / 'hashes' / etag
            self.assertEqual(fsx_object.read_text(encoding='utf-8'), 'fsx-output')
            manifest_entry = common.ManifestEntry.from_tuple(manifest_cache[0])
            self.assertEqual(
                manifest_entry.storage_path,
                f's3://bucket/datasets/dataset-id/hashes/{etag}',
            )
            self.assertEqual(storage_path_cache[0], manifest_entry.storage_path)
            self.assertEqual(output.size_transferred, source.stat().st_size)
            self.assertEqual(output.count_transferred, 1)

    def test_finalize_manifest_to_fsx_writes_json_manifest(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            fsx_root = root / 'fsx'
            config = fsx_lustre.FSxLustreConfig(mounts=[
                fsx_lustre.FSxLustreMount(
                    storage_path='s3://bucket/datasets',
                    mount_path=str(fsx_root),
                ),
            ])
            manifest_cache = diskcache.Index()
            manifest_cache[0] = common.ManifestEntry(
                relative_path='source.txt',
                storage_path='s3://bucket/datasets/dataset-id/hashes/abc',
                url='https://bucket.s3.us-east-1.amazonaws.com/datasets/dataset-id/hashes/abc',
                size=10,
                etag='abc',
            ).to_tuple()

            checksum = fsx_lustre.finalize_manifest_to_fsx(
                manifest_cache,
                's3://bucket/datasets/dataset-id/manifests/1.json',
                config,
            )

            manifest_path = fsx_root / 'dataset-id' / 'manifests' / '1.json'
            manifest_payload = json.loads(manifest_path.read_text(encoding='utf-8'))
            expected_checksum = hashlib.md5()
            expected_checksum.update('source.txt abc'.encode())
            self.assertEqual(manifest_payload[0]['relative_path'], 'source.txt')
            self.assertEqual(checksum, expected_checksum.hexdigest())

    def test_dataset_upload_worker_shares_manifest_cache_across_processes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            upload_root = root / 'upload'
            upload_root.mkdir()
            source = upload_root / 'source.txt'
            source.write_text('fsx-output', encoding='utf-8')
            fsx_root = root / 'fsx'
            config = fsx_lustre.FSxLustreConfig(mounts=[
                fsx_lustre.FSxLustreMount(
                    storage_path='s3://bucket/datasets',
                    mount_path=str(fsx_root),
                ),
            ])
            destination = storage.construct_storage_backend(
                's3://bucket/datasets/dataset-id/hashes',
            )
            manifest_cache = diskcache.Index()
            storage_path_cache = diskcache.Index()

            worker_input_gen = uploading._dataset_upload_worker_input_generator(  # pylint: disable=protected-access
                local_paths=[common.LocalPath(path=str(upload_root))],
                remote_paths=[],
                destination=destination,
                destination_region='us-east-1',
                manifest_cache=manifest_cache,
                regex=None,
                fsx_lustre_config=config,
                fsx_lustre_storage_path_cache=storage_path_cache,
            )

            job_context = executor.run_job(
                thread_worker=uploading.dataset_upload_worker,
                thread_worker_input_gen=worker_input_gen,
                client_factory=destination.client_factory(region='us-east-1'),
                enable_progress_tracker=False,
                executor_params=executor.ExecutorParameters(num_processes=2, num_threads=1),
            )

            self.assertEqual(job_context.errors, [])
            self.assertIn(0, manifest_cache)
            etag = utils_common.etag_checksum(str(source))
            self.assertEqual(
                common.ManifestEntry.from_tuple(manifest_cache[0]).storage_path,
                f's3://bucket/datasets/dataset-id/hashes/{etag}',
            )
            self.assertEqual(storage_path_cache[0], f's3://bucket/datasets/dataset-id/hashes/{etag}')


if __name__ == '__main__':
    unittest.main()
