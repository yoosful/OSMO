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
	"slices"
	"strings"
	"testing"
)

func testEnvMap(env []string) map[string]string {
	envMap := make(map[string]string, len(env))
	for _, entry := range env {
		key, value, found := strings.Cut(entry, "=")
		if found {
			envMap[key] = value
		}
	}
	return envMap
}

func requireEnvValue(t *testing.T, envMap map[string]string, key string, expected string) {
	t.Helper()
	if got := envMap[key]; got != expected {
		t.Fatalf("expected %s=%q, got %q", key, expected, got)
	}
}

func requireEnvMissing(t *testing.T, envMap map[string]string, key string) {
	t.Helper()
	if value, ok := envMap[key]; ok {
		t.Fatalf("expected %s to be unset, got %q", key, value)
	}
}

func TestAwsCredentialCommandEnvStaticCredentialOverridesAmbient(t *testing.T) {
	env := awsCredentialCommandEnv([]string{
		"AWS_ACCESS_KEY_ID=ambient-id",
		"AWS_SECRET_ACCESS_KEY=ambient-secret",
		"AWS_SESSION_TOKEN=ambient-session",
		"AWS_REGION=us-east-1",
		"OSMO_TEST=value",
	}, DataCredential{
		AccessKeyId: "static-id",
		AccessKey:   "static-secret",
		Region:      "us-west-2",
	}, true)

	envMap := testEnvMap(env)
	requireEnvValue(t, envMap, "AWS_ACCESS_KEY_ID", "static-id")
	requireEnvValue(t, envMap, "AWS_SECRET_ACCESS_KEY", "static-secret")
	requireEnvValue(t, envMap, "AWS_REGION", "us-west-2")
	requireEnvValue(t, envMap, "OSMO_TEST", "value")
	requireEnvMissing(t, envMap, "AWS_SESSION_TOKEN")
}

func TestAwsCredentialCommandEnvDefaultCredentialPreservesAmbientAuth(t *testing.T) {
	env := awsCredentialCommandEnv([]string{
		"AWS_ACCESS_KEY_ID=ambient-id",
		"AWS_SECRET_ACCESS_KEY=ambient-secret",
		"AWS_SESSION_TOKEN=ambient-session",
		"AWS_REGION=us-east-1",
	}, DataCredential{
		Region: "us-west-2",
	}, true)

	envMap := testEnvMap(env)
	requireEnvValue(t, envMap, "AWS_ACCESS_KEY_ID", "ambient-id")
	requireEnvValue(t, envMap, "AWS_SECRET_ACCESS_KEY", "ambient-secret")
	requireEnvValue(t, envMap, "AWS_SESSION_TOKEN", "ambient-session")
	requireEnvValue(t, envMap, "AWS_REGION", "us-west-2")
}

func TestAwsCredentialCommandEnvNoCredentialPreservesAmbientAuth(t *testing.T) {
	env := awsCredentialCommandEnv([]string{
		"AWS_ACCESS_KEY_ID=ambient-id",
		"AWS_SECRET_ACCESS_KEY=ambient-secret",
		"AWS_SESSION_TOKEN=ambient-session",
		"AWS_REGION=us-east-1",
	}, DataCredential{}, false)

	envMap := testEnvMap(env)
	requireEnvValue(t, envMap, "AWS_ACCESS_KEY_ID", "ambient-id")
	requireEnvValue(t, envMap, "AWS_SECRET_ACCESS_KEY", "ambient-secret")
	requireEnvValue(t, envMap, "AWS_SESSION_TOKEN", "ambient-session")
	requireEnvValue(t, envMap, "AWS_REGION", "us-east-1")
}

func TestBuildMountCommandArgsS3VirtualCustomEndpoint(t *testing.T) {
	backend := ParseStorageBackend("s3://coreweave-bucket/datasets")
	credential := DataCredential{
		OverrideUrl:     "https://cwobject.com",
		AddressingStyle: "virtual",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if !slices.Contains(args, "--endpoint-url") {
		t.Fatalf("expected endpoint URL flag in args: %v", args)
	}
	if !slices.Contains(args, "https://cwobject.com") {
		t.Fatalf("expected CoreWeave endpoint URL in args: %v", args)
	}
	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("virtual addressing must not force path style: %v", args)
	}
	if !slices.Contains(args, "--prefix=datasets/") {
		t.Fatalf("expected S3 prefix in args: %v", args)
	}
}

func TestBuildMountCommandArgsS3CustomEndpointDefaultsVirtual(t *testing.T) {
	t.Setenv(osmoS3AddressingStyle, "")
	t.Setenv(awsS3ForcePathStyle, "")
	backend := ParseStorageBackend("s3://coreweave-bucket/datasets")
	credential := DataCredential{
		OverrideUrl: "https://cwobject.com",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("custom S3 endpoint should default to virtual addressing: %v", args)
	}
	if !slices.Contains(args, "https://cwobject.com") {
		t.Fatalf("expected CoreWeave endpoint URL in args: %v", args)
	}
}

func TestBuildMountCommandArgsS3PathCustomEndpoint(t *testing.T) {
	backend := ParseStorageBackend("s3://localstack-bucket/datasets")
	credential := DataCredential{
		OverrideUrl:     "http://localstack-s3.osmo:4566",
		AddressingStyle: "path",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if !slices.Contains(args, "--endpoint-url") {
		t.Fatalf("expected endpoint URL flag in args: %v", args)
	}
	if !slices.Contains(args, "http://localstack-s3.osmo:4566") {
		t.Fatalf("expected localstack endpoint URL in args: %v", args)
	}
	if !slices.Contains(args, "--force-path-style") {
		t.Fatalf("path addressing must force path style: %v", args)
	}
}

func TestBuildMountCommandArgsS3CustomEndpointRespectsForcePathEnv(t *testing.T) {
	t.Setenv(osmoS3AddressingStyle, "")
	t.Setenv(awsS3ForcePathStyle, "true")
	backend := ParseStorageBackend("s3://localstack-bucket/datasets")
	credential := DataCredential{
		OverrideUrl: "http://localstack-s3.osmo:4566",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if !slices.Contains(args, "--force-path-style") {
		t.Fatalf("AWS_S3_FORCE_PATH_STYLE must force path style: %v", args)
	}
}

func TestBuildMountCommandArgsTOSDoesNotForcePathStyle(t *testing.T) {
	// Regression guard: TOS only supports virtual-hosted style.
	backend := ParseStorageBackend("tos://tos.example.com/my-bucket/data")
	credential := DataCredential{}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("TOS must not force path style: %v", args)
	}
}

func TestBuildMountCommandArgsAwsS3WithoutOverrideForcesPathStyle(t *testing.T) {
	// Preserved behavior: plain AWS S3 (no override_url, no env hints) still gets
	// --force-path-style. Codex's refactor intentionally kept this.
	t.Setenv(osmoS3AddressingStyle, "")
	t.Setenv(awsS3ForcePathStyle, "")
	backend := ParseStorageBackend("s3://aws-bucket/data")
	credential := DataCredential{}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if !slices.Contains(args, "--force-path-style") {
		t.Fatalf("AWS S3 without override_url must force path style (preserved): %v", args)
	}
	if slices.Contains(args, "--endpoint-url") {
		t.Fatalf("AWS S3 with no override_url must not pass --endpoint-url: %v", args)
	}
}

func TestBuildMountCommandArgsSwiftForcesPathStyle(t *testing.T) {
	// Preserved behavior: Swift's S3 API uses path-style addressing.
	t.Setenv(osmoS3AddressingStyle, "")
	t.Setenv(awsS3ForcePathStyle, "")
	backend := ParseStorageBackend("swift://swift.example.com/AUTH_ns/my-bucket/data")
	credential := DataCredential{}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if !slices.Contains(args, "--force-path-style") {
		t.Fatalf("Swift must force path style: %v", args)
	}
}

func TestBuildMountCommandArgsOsmoEnvVarSelectsVirtual(t *testing.T) {
	// OSMO_S3_ADDRESSING_STYLE=virtual flips even no-override AWS S3 to virtual.
	t.Setenv(osmoS3AddressingStyle, "virtual")
	t.Setenv(awsS3ForcePathStyle, "")
	backend := ParseStorageBackend("s3://aws-bucket/data")
	credential := DataCredential{}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("OSMO_S3_ADDRESSING_STYLE=virtual must override the default: %v", args)
	}
}

func TestBuildMountCommandArgsAutoFallsThroughToHeuristic(t *testing.T) {
	// 'auto' is accepted by the credential schema (Literal['virtual','path','auto'])
	// but the runtime intentionally does NOT mirror boto3's 'auto', which would
	// pick path-style for any custom endpoint and re-break CAIOS. Treat 'auto'
	// as "use OSMO's heuristic" — same as an unset value.
	t.Setenv(osmoS3AddressingStyle, "")
	t.Setenv(awsS3ForcePathStyle, "")
	backend := ParseStorageBackend("s3://coreweave-bucket/data")
	credential := DataCredential{
		OverrideUrl:     "https://cwobject.com",
		AddressingStyle: "auto",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("'auto' with override_url must fall through to virtual-host: %v", args)
	}
}

func TestBuildMountCommandArgsCredentialBeatsEnv(t *testing.T) {
	// Per-credential addressing_style takes precedence over both env vars.
	t.Setenv(osmoS3AddressingStyle, "path")
	t.Setenv(awsS3ForcePathStyle, "true")
	backend := ParseStorageBackend("s3://coreweave-bucket/data")
	credential := DataCredential{
		OverrideUrl:     "https://cwobject.com",
		AddressingStyle: "virtual",
	}

	args := buildMountCommandArgs(backend, credential, "/mnt/input", "/mnt/cache", 0)

	if slices.Contains(args, "--force-path-style") {
		t.Fatalf("credential addressing_style=virtual must override env vars: %v", args)
	}
}
