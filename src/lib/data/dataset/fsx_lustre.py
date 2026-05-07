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

"""
FSx for Lustre helpers for S3-backed dataset writes.
"""

import dataclasses
import contextlib
import hashlib
import json
import logging
import os
import tempfile
import time
from typing import Iterable, List

import diskcache

from . import common
from .. import storage
from ..storage.core import progress
from ...utils import osmo_errors


logger = logging.getLogger(__name__)

COPY_CHUNK_SIZE = 8 * 1024 * 1024


@dataclasses.dataclass(frozen=True, slots=True)
class FSxLustreMount:
    """
    Mapping from an S3 storage prefix to its local FSx for Lustre mount path.
    """

    storage_path: str
    mount_path: str


@dataclasses.dataclass(frozen=True, slots=True)
class FSxLustreConfig:
    """
    Runtime FSx for Lustre mapping config.
    """

    mounts: List[FSxLustreMount]


def load_config(config_path: str | None) -> FSxLustreConfig | None:
    """
    Loads an FSx for Lustre mapping config. Empty paths disable FSx writes.
    """
    if not config_path:
        return None
    with open(config_path, 'r', encoding='utf-8') as file:
        payload = json.load(file)
    return FSxLustreConfig(
        mounts=[
            FSxLustreMount(
                storage_path=mount['storage_path'],
                mount_path=mount['mount_path'],
            )
            for mount in payload.get('mounts', [])
        ],
    )


def _normalize_storage_prefix(storage_path: str) -> str:
    return storage_path.rstrip('/')


def _normalize_mount_path(mount_path: str) -> str:
    normalized = mount_path.rstrip('/')
    return normalized or '/'


def _storage_prefix_matches(storage_path: str, prefix: str) -> bool:
    return storage_path == prefix or storage_path.startswith(f'{prefix}/')


def resolve_path(storage_path: str, config: FSxLustreConfig) -> str:
    """
    Resolves a storage URI to the corresponding local FSx for Lustre path.
    """
    best_mount: FSxLustreMount | None = None
    best_prefix_length = -1
    for mount in config.mounts:
        prefix = _normalize_storage_prefix(mount.storage_path)
        if not prefix or not mount.mount_path:
            continue
        if _storage_prefix_matches(storage_path, prefix) and len(prefix) > best_prefix_length:
            best_mount = FSxLustreMount(
                storage_path=prefix,
                mount_path=_normalize_mount_path(mount.mount_path),
            )
            best_prefix_length = len(prefix)

    if best_mount is None:
        raise osmo_errors.OSMODatasetError(
            f'No FSx Lustre mount configured for storage path {storage_path}',
        )

    relative_path = storage_path.removeprefix(best_mount.storage_path).lstrip('/')
    if not relative_path:
        return best_mount.mount_path
    return os.path.join(best_mount.mount_path, *relative_path.split('/'))


def matches_path(storage_path: str, config: FSxLustreConfig | None) -> bool:
    """
    Returns whether a storage path has an FSx for Lustre mapping.
    """
    if config is None:
        return False
    try:
        resolve_path(storage_path, config)
        return True
    except osmo_errors.OSMODatasetError:
        return False


def copy_file_to_fsx(
    source: str,
    destination_storage_path: str,
    config: FSxLustreConfig,
    progress_updater: progress.ProgressUpdater,
    *,
    overwrite: bool = False,
) -> bool:
    """
    Copies a local file to FSx for Lustre using the mapped destination storage URI.

    Returns True when bytes were copied and False when an existing content-addressed file
    was reused.
    """
    destination = resolve_path(destination_storage_path, config)
    source_size = os.path.getsize(source)
    if os.path.exists(destination) and not overwrite:
        progress_updater.update(name=source, amount_change=source_size)
        return False

    os.makedirs(os.path.dirname(destination), exist_ok=True)
    progress_updater.update(name=source)
    temp_path = ''
    try:
        with tempfile.NamedTemporaryFile(
            mode='wb',
            dir=os.path.dirname(destination),
            prefix=f'.{os.path.basename(destination)}.',
            delete=False,
        ) as temp_file:
            temp_path = temp_file.name
            with open(source, 'rb') as source_file:
                while True:
                    chunk = source_file.read(COPY_CHUNK_SIZE)
                    if not chunk:
                        break
                    temp_file.write(chunk)
                    progress_updater.update(amount_change=len(chunk))
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_path, destination)
        temp_path = ''
        return True
    finally:
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)


def finalize_manifest_to_fsx(
    manifest_cache: diskcache.Index,
    manifest_path: str,
    config: FSxLustreConfig,
    *,
    enable_progress_tracker: bool = False,
) -> str:
    """
    Writes a dataset manifest to FSx for Lustre and returns its checksum.
    """
    if len(manifest_cache) == 0:
        raise osmo_errors.OSMODatasetError('No objects in Dataset. Aborting...')

    logger.info('Writing manifest file to FSx Lustre...')
    checksum = hashlib.md5()
    successful_indices = sorted(manifest_cache.keys())
    progress_updater: progress.ProgressUpdater
    tracker_ctx, progress_updater = (
        progress.create_single_thread_progress(
            desc='Writing manifest',
            unit='files',
            total=len(successful_indices),
        ) if enable_progress_tracker else
        (None, progress.NoOpProgressUpdater())
    )
    context_manager = tracker_ctx if tracker_ctx is not None else contextlib.nullcontext()

    with context_manager, tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as manifest_file:
        manifest_file.write('[\n')
        for position, index in enumerate(successful_indices):
            if position > 0:
                manifest_file.write(',\n')
            manifest_entry = common.ManifestEntry.from_tuple(manifest_cache[index])
            manifest_file.write(json.dumps(manifest_entry.to_json(), indent=4))
            checksum.update(f'{manifest_entry.relative_path} {manifest_entry.etag}'.encode())
            progress_updater.update(amount_change=1)
        manifest_file.write('\n]')
        manifest_file.flush()

        copy_file_to_fsx(
            source=manifest_file.name,
            destination_storage_path=manifest_path,
            config=config,
            progress_updater=progress.NoOpProgressUpdater(),
            overwrite=True,
        )

    return checksum.hexdigest()


def _storage_object_exists(storage_path: str) -> bool:
    storage_backend = storage.construct_storage_backend(storage_path)
    if storage_backend.scheme != 's3':
        return True
    client_factory = storage_backend.client_factory(
        region=storage_backend.region(),
    )
    with client_factory.to_provider().get() as storage_client:
        return storage_client.object_exists(
            bucket=storage_backend.container,
            key=storage_backend.path,
        ).result.exists


def wait_for_exported_objects(
    storage_paths: Iterable[str],
    *,
    timeout_seconds: int,
    poll_seconds: int,
) -> None:
    """
    Waits until FSx-written S3 objects are visible through the storage backend.
    """
    pending = set(storage_paths)
    deadline = time.monotonic() + timeout_seconds
    while pending:
        ready: set[str] = set()
        for storage_path in pending:
            if _storage_object_exists(storage_path):
                ready.add(storage_path)
        pending -= ready
        if not pending:
            return
        if time.monotonic() >= deadline:
            sample = ', '.join(sorted(pending)[:5])
            raise osmo_errors.OSMODatasetError(
                'Timed out waiting for FSx Lustre writes to appear in S3. '
                'Verify FSx Data Repository Association auto export is enabled. '
                f'Pending objects: {sample}',
            )
        time.sleep(poll_seconds)
