/*
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

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
*/

package data

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type FSxLustreMount struct {
	StoragePath string `json:"storage_path"`
	MountPath   string `json:"mount_path"`
}

type FSxLustreConfig struct {
	Mounts []FSxLustreMount `json:"mounts"`
}

func LoadFSxLustreConfig(configPath string) (FSxLustreConfig, error) {
	config := FSxLustreConfig{}
	if configPath == "" {
		return config, nil
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return config, err
	}
	if err := json.Unmarshal(data, &config); err != nil {
		return config, err
	}
	return config, nil
}

func normalizeStoragePrefix(storagePath string) string {
	return strings.TrimRight(storagePath, "/")
}

func normalizeMountPath(mountPath string) string {
	normalized := strings.TrimRight(mountPath, "/")
	if normalized == "" {
		return "/"
	}
	return normalized
}

func storagePrefixMatches(storagePath string, prefix string) bool {
	return storagePath == prefix || strings.HasPrefix(storagePath, prefix+"/")
}

func ResolveFSxLustrePath(storagePath string, config FSxLustreConfig) (string, error) {
	var bestMount FSxLustreMount
	bestPrefixLength := -1
	for _, mount := range config.Mounts {
		prefix := normalizeStoragePrefix(mount.StoragePath)
		if prefix == "" || mount.MountPath == "" {
			continue
		}
		if storagePrefixMatches(storagePath, prefix) && len(prefix) > bestPrefixLength {
			bestMount = FSxLustreMount{
				StoragePath: prefix,
				MountPath:   normalizeMountPath(mount.MountPath),
			}
			bestPrefixLength = len(prefix)
		}
	}
	if bestPrefixLength < 0 {
		return "", fmt.Errorf("no FSx Lustre mount configured for storage path %s", storagePath)
	}
	relativePath := strings.TrimPrefix(storagePath, bestMount.StoragePath)
	relativePath = strings.TrimPrefix(relativePath, "/")
	if relativePath == "" {
		return bestMount.MountPath, nil
	}
	return filepath.Join(bestMount.MountPath, filepath.FromSlash(relativePath)), nil
}

func LinkFSxLustreManifest(manifestFilePath string, config FSxLustreConfig,
	destination string, regex string) (int, error) {
	var regexFilter *regexp.Regexp
	if regex != "" {
		compiled, err := regexp.Compile(regex)
		if err != nil {
			return 0, err
		}
		regexFilter = compiled
	}

	file, err := os.Open(manifestFilePath)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	decoder := json.NewDecoder(bufio.NewReader(file))
	if _, err := decoder.Token(); err != nil {
		return 0, err
	}

	linkedFiles := 0
	for decoder.More() {
		var manifestObject ManifestObject
		if err := decoder.Decode(&manifestObject); err != nil {
			return linkedFiles, err
		}
		if regexFilter != nil && !regexFilter.MatchString(manifestObject.RelativePath) {
			continue
		}

		source, err := ResolveFSxLustrePath(manifestObject.StoragePath, config)
		if err != nil {
			return linkedFiles, err
		}
		if _, err := os.Stat(source); err != nil {
			return linkedFiles, fmt.Errorf(
				"FSx Lustre source for %s is unavailable at %s: %w",
				manifestObject.StoragePath, source, err)
		}

		target := filepath.Join(destination, filepath.FromSlash(manifestObject.RelativePath))
		if err := os.MkdirAll(filepath.Dir(target), 0777); err != nil {
			return linkedFiles, err
		}
		if err := os.Symlink(source, target); err != nil {
			return linkedFiles, err
		}
		linkedFiles++
	}
	return linkedFiles, nil
}
