# codecommit repo

resource "aws_codecommit_repository" "this" {
    for_each        = { for entry in local.repositories_deploy : "${entry.id}" => entry }
    repository_name = "${local.resource_prefix}-${each.value.name}"
    description     = "${each.value.name} repository"
}

# codecommit repo Rules
resource "aws_codecommit_approval_rule_template" "automatic" {
    name        = "lambda_automatic_approval"
    description = "approval rule template for lambda function "

    content = jsonencode({
        Version               = "2018-11-08"
        DestinationReferences = ["refs/heads/master"]
        Statements = [{
        Type                    = "Approvers"
        NumberOfApprovalsNeeded = 1
        ApprovalPoolMembers     = aws_iam_role.lambda.arn #lambda role
        }]
    })
}

resource "aws_codecommit_approval_rule_template" "reviewers" {
    for_each    = { for entry in local.approval_templates_deploy : "${entry.id}" => entry }
    name        = each.value.name
    description = "additional approval rule template for use across multiple repositories"

    content = jsonencode({
        Version               = "2018-11-08"
        DestinationReferences = ["refs/heads/master"]
        Statements = [{
        Type                    = "Approvers"
        NumberOfApprovalsNeeded = each.value.approvals_needed
        ApprovalPoolMembers     = each.value.pool_members
        }]
    })
}

# Parsing for Codecommit 
locals {
    repositories = values(aws_codecommit_repository.this)[*].repository_name
    approval_templates_reviewers = values(aws_codecommit_approval_rule_template.reviewers)[*].name
    approval_templates = concat(local.approval_templates_reviewers, [tostring(aws_codecommit_approval_rule_template.automatic.name)])
    template_associations_input = setproduct(local.repositories, local.approval_templates)
    template_associations = [
        for item in local.template_associations_input : merge({repo = item[0]}, {template = item[1]})
    ]
}

resource "aws_codecommit_approval_rule_template_association" "this" {
    for_each                    = { for i in local.template_associations : "${i.repo}-${i.template}" =>  i } 
    approval_rule_template_name = each.value.repo
    repository_name             = each.value.template
}

# codecommit IAM roles
resource "aws_iam_role" "this" {
    for_each           = { for entry in local.assumed_roles_deploy : "${entry.id}" => entry }
    name               = each.value.name
    assume_role_policy = data.aws_iam_policy_document.this[each.value.id].json
}

data "aws_iam_policy_document" "this" {
    for_each           = { for entry in local.assumed_roles_deploy : "${entry.id}" => entry }
    statement {
        effect = "Allow"
        principals {
        type        = "Service"
        identifiers = ["lambda.amazonaws.com"]
        }
        actions = ["sts:AssumeRole"]
    }
}

resource "aws_iam_role" "lambda" {
    name               = "iam_for_lambda"
    assume_role_policy = data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "lambda" {
    statement {
        effect = "Allow"
        principals {
        type        = "Service"
        identifiers = ["lambda.amazonaws.com"]
        }
        actions = ["sts:AssumeRole"]
    }
}

# codebuild - test phase
resource "aws_codebuild_project" "this" {
    name          = "test-project"
    description   = "test_codebuild_project"
    build_timeout = 5
    service_role  = aws_iam_role.lambda.arn #should be the lambda ARN for automation

    artifacts {
        type = "NO_ARTIFACTS"
    }

    cache {
        type     = "S3"
        location = aws_s3_bucket.example.bucket
    }

    environment {
        compute_type                = "BUILD_GENERAL1_SMALL"
        image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
        type                        = "LINUX_CONTAINER"
        image_pull_credentials_type = "CODEBUILD"

        environment_variable {
        name  = "SOME_KEY2"
        value = "SOME_VALUE2"
        type  = "PARAMETER_STORE"
        }
    }

    logs_config {
        cloudwatch_logs {
        group_name  = "log-group"
        stream_name = "log-stream"
        }
    }

    source {
        type            = "GITHUB"
        location        = "https://github.com/mitchellh/packer.git"
        git_clone_depth = 1

        git_submodules_config {
        fetch_submodules = true
        }
    }

    source_version = "master"



    tags = {
        Environment = "Test"
    }
}

# codebuild - test phase event triggers


# codebuild - build phase


# codebuild - build phase event triggers


# lambda function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "lambda_publish_build_result/handler.py"
  output_path = "lambda_function_payload.zip"
}
resource "aws_lambda_function" "lambda" {
    # If the file is not in the current working directory you will need to include a
    # path.module in the filename.
    filename      = "lambda_function_payload.zip"
    function_name = "${local.resource_prefix}-PullRequestAutomation"
    role          = aws_iam_role.lambda.arn
    handler       = "handler.py"

    runtime = "python3.7"

    # environment {
    #     variables = {
    #         foo = "bar"
    #     }
    # }
}