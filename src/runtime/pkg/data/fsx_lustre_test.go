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
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveFSxLustrePathUsesLongestPrefix(t *testing.T) {
	config := FSxLustreConfig{Mounts: []FSxLustreMount{
		{StoragePath: "s3://bucket/datasets", MountPath: "/fsx/root"},
		{StoragePath: "s3://bucket/datasets/special", MountPath: "/fsx/special"},
	}}

	got, err := ResolveFSxLustrePath("s3://bucket/datasets/special/file.txt", config)
	if err != nil {
		t.Fatalf("ResolveFSxLustrePath returned error: %v", err)
	}
	want := filepath.Join("/fsx/special", "file.txt")
	if got != want {
		t.Fatalf("ResolveFSxLustrePath = %q, want %q", got, want)
	}
}

func TestLinkFSxLustreManifestCreatesFilteredSymlinks(t *testing.T) {
	root := t.TempDir()
	fsxRoot := filepath.Join(root, "fsx")
	sourcePath := filepath.Join(fsxRoot, "dataset-id", "hashes", "keep.txt")
	if err := os.MkdirAll(filepath.Dir(sourcePath), 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sourcePath, []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}

	manifestPath := filepath.Join(root, "manifest.json")
	manifest := `[
		{"relative_path":"keep.txt","storage_path":"s3://bucket/datasets/dataset-id/hashes/keep.txt"},
		{"relative_path":"skip.bin","storage_path":"s3://bucket/datasets/dataset-id/hashes/skip.bin"}
	]`
	if err := os.WriteFile(manifestPath, []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}

	destination := filepath.Join(root, "input")
	linkedFiles, err := LinkFSxLustreManifest(
		manifestPath,
		FSxLustreConfig{Mounts: []FSxLustreMount{
			{StoragePath: "s3://bucket/datasets", MountPath: fsxRoot},
		}},
		destination,
		`.*\.txt$`,
	)
	if err != nil {
		t.Fatalf("LinkFSxLustreManifest returned error: %v", err)
	}
	if linkedFiles != 1 {
		t.Fatalf("LinkFSxLustreManifest linked %d files, want 1", linkedFiles)
	}
	linkPath := filepath.Join(destination, "keep.txt")
	target, err := os.Readlink(linkPath)
	if err != nil {
		t.Fatalf("expected symlink at %s: %v", linkPath, err)
	}
	if target != sourcePath {
		t.Fatalf("symlink target = %q, want %q", target, sourcePath)
	}
	if _, err := os.Lstat(filepath.Join(destination, "skip.bin")); !os.IsNotExist(err) {
		t.Fatalf("filtered file should not be linked, lstat err: %v", err)
	}
}

func TestLinkFSxLustreManifestFailsWhenSourceMissing(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	manifest := `[
		{"relative_path":"missing.txt","storage_path":"s3://bucket/datasets/missing.txt"}
	]`
	if err := os.WriteFile(manifestPath, []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}

	_, err := LinkFSxLustreManifest(
		manifestPath,
		FSxLustreConfig{Mounts: []FSxLustreMount{
			{StoragePath: "s3://bucket/datasets", MountPath: filepath.Join(root, "fsx")},
		}},
		filepath.Join(root, "input"),
		"",
	)
	if err == nil {
		t.Fatal("LinkFSxLustreManifest returned nil error for missing source")
	}
	if !strings.Contains(err.Error(), "FSx Lustre source") {
		t.Fatalf("error = %q, want missing FSx Lustre source context", err.Error())
	}
}

func TestAppendFSxLustreDatasetWriteArgs(t *testing.T) {
	got := AppendFSxLustreDatasetWriteArgs(
		[]string{"osmo", "dataset", "upload"},
		FSxLustre,
		"/osmo/fsx_lustre_config.json",
	)
	want := []string{
		"osmo",
		"dataset",
		"upload",
		"--fsx-lustre-config",
		"/osmo/fsx_lustre_config.json",
	}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("AppendFSxLustreDatasetWriteArgs = %#v, want %#v", got, want)
	}

	got = AppendFSxLustreDatasetWriteArgs(
		[]string{"osmo", "dataset", "upload"},
		Download,
		"/osmo/fsx_lustre_config.json",
	)
	if len(got) != 3 {
		t.Fatalf("Download mode should not append FSx args: %#v", got)
	}
}
