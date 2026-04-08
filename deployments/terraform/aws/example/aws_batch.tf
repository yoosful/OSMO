# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

################################################################################
# AWS Batch on EKS (Optional)
#
# Enables AWS Batch as a scheduler for OSMO workflows on the EKS cluster.
# Set var.enable_aws_batch = true to deploy these resources.
################################################################################

resource "aws_batch_compute_environment" "osmo" {
  count = var.enable_aws_batch ? 1 : 0

  compute_environment_name = "${local.name}-osmo-batch"
  type                     = "MANAGED"
  state                    = "ENABLED"
  service_role             = aws_iam_role.batch_service[0].arn

  eks_configuration {
    eks_cluster_arn = module.eks.cluster_arn
    kubernetes_namespace = var.aws_batch_namespace
  }

  tags = local.tags

  depends_on = [module.eks]
}

resource "aws_batch_job_queue" "osmo" {
  count = var.enable_aws_batch ? 1 : 0

  name     = "${local.name}-osmo-queue"
  state    = "ENABLED"
  priority = 10

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.osmo[0].arn
  }

  tags = local.tags
}

################################################################################
# IAM Roles for AWS Batch
################################################################################

# Batch service role
resource "aws_iam_role" "batch_service" {
  count = var.enable_aws_batch ? 1 : 0

  name = "${local.name}-batch-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "batch.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  count = var.enable_aws_batch ? 1 : 0

  role       = aws_iam_role.batch_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# Batch execution role (for pulling container images)
resource "aws_iam_role" "batch_execution" {
  count = var.enable_aws_batch ? 1 : 0

  name = "${local.name}-batch-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "batch_execution" {
  count = var.enable_aws_batch ? 1 : 0

  role       = aws_iam_role.batch_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IRSA role for the OSMO backend worker pod to call AWS Batch APIs
resource "aws_iam_role" "batch_worker_irsa" {
  count = var.enable_aws_batch ? 1 : 0

  name = "${local.name}-batch-worker-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${var.aws_batch_namespace}:${var.aws_batch_worker_service_account}"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "batch_worker" {
  count = var.enable_aws_batch ? 1 : 0

  name = "${local.name}-batch-worker-policy"
  role = aws_iam_role.batch_worker_irsa[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:TerminateJob",
          "batch:CancelJob",
          "batch:RegisterJobDefinition",
          "batch:DeregisterJobDefinition",
          "batch:DescribeJobDefinitions",
          "batch:ListJobs",
        ]
        Resource = "*"
      }
    ]
  })
}
