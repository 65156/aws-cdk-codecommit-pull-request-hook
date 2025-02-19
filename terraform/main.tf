#       ---------------------------------------------
#   ▪  ▄▄▄▄· • ▌ ▄ ·.     .▄▄ ·  ▄▄▄·      ▄▄▄  ▄▄▄▄▄.▄▄ · 
#   ██ ▐█ ▀█▪·██ ▐███▪    ▐█ ▀. ▐█ ▄█▪     ▀▄ █·•██  ▐█ ▀. 
#   ▐█·▐█▀▀█▄▐█ ▌▐▌▐█·    ▄▀▀▀█▄ ██▀· ▄█▀▄ ▐▀▀▄  ▐█.▪▄▀▀▀█▄
#   ▐█▌██▄▪▐███ ██▌▐█▌    ▐█▄▪▐█▐█▪·•▐█▌.▐▌▐█•█▌ ▐█▌·▐█▄▪▐█
#   ▀▀▀·▀▀▀▀ ▀▀  █▪▀▀▀     ▀▀▀▀ .▀    ▀█▄▀▪.▀  ▀ ▀▀▀  ▀▀▀▀ 
#       ---------------------------------------------
## >> .summary
# builds out multiple AWS codecommit repositories with 2 stage codebuild and a single 
# shared lambda function for enabling CICD automation in codecommit.

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
      ApprovalPoolMembers     = aws_iam_role.cicd.arn #lambda role
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
      ApprovalPoolMembers     = [values(aws_iam_role.this)[*].arn]
    }]
  })
}

# Parsing for Codecommit 
locals {
  repositories                 = values(aws_codecommit_repository.this)[*].repository_name
  approval_templates_reviewers = values(aws_codecommit_approval_rule_template.reviewers)[*].name
  approval_templates           = concat(local.approval_templates_reviewers, [tostring(aws_codecommit_approval_rule_template.automatic.name)])
  template_associations_input  = setproduct(local.repositories, local.approval_templates)
  template_associations = [
    for item in local.template_associations_input : merge({ repo = item[0] }, { template = item[1] })
  ]
}

resource "aws_codecommit_approval_rule_template_association" "this" {
  for_each                    = { for i in local.template_associations : "${i.repo}-${i.template}" => i }
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
  for_each = { for entry in local.assumed_roles_deploy : "${entry.id}" => entry }
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cicd" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.cicd.json
}

data "aws_iam_policy_document" "cicd" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
  statement {
    effect = "Allow"
    resources = ["*"]
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
      ]
  }
  statement {
    effect = "Allow"
    resources = [for i in values(aws_codecommit_repository.this)[*] : i.arn]
    actions = [
      "codecommit:UpdatePullRequestApprovalState",
      "codecommit:PostCommentForPullRequest",
      "codecommit:MergePullRequestByFastForward",
      "codecommit:GetPullRequest"
      ]
  }
}



# codebuild - test execution environment triggers
resource "aws_cloudwatch_event_rule" "pr" {
  for_each    = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  name        = "${each.value.name}-codebuild-pr-rule"
  description = "initiates test execution environment on PR merge"

  event_pattern = jsonencode({
    resources = [tostring(aws_codecommit_repository.this["${each.value.id}"].arn)]
    detail = {
      event = ["pullRequestCreated", "pullRequestSourceBranchUpdated"]
    }
    source = ["aws.codecommit"]
  })
  role_arn = aws_iam_role.cicd.arn
}
# {
#   "resources": ["arn:aws:codecommit:eu-central-1:181579366464:ferrari-infra-testing"],
#   "detail": {
#     "event": 
#   },
#   "source": ["aws.codecommit"]
# }

resource "aws_cloudwatch_event_target" "pr" {
  for_each = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  rule     = aws_cloudwatch_event_rule.pr["${each.value.id}"].name
  arn      = aws_codebuild_project.pr["${each.value.id}"].arn
}

# codebuild - test phase
resource "aws_codebuild_project" "pr" {
  for_each      = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  name          = "${each.value.name}-pr"
  description   = "${each.value.name} pr execution environment"
  build_timeout = 5
  service_role  = aws_iam_role.cicd.arn #should be the lambda ARN for automation

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

  }

  logs_config {
    cloudwatch_logs {
      group_name  = "log-group"
      stream_name = "log-stream"
    }
  }

  source {
    type            = "CODECOMMIT"
    location        = aws_codecommit_repository.this["${each.value.id}"].clone_url_http
    git_clone_depth = 1
  }

  source_version = "main"

}

# codebuild - lambda execution triggers
resource "aws_cloudwatch_event_rule" "lambda" {
  for_each = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  name     = "${each.value.name}-lamda-execution"

  description = "initiates lambda function on codebuild test execution outcome"

  event_pattern = jsonencode({
    detail-type = ["CodeBuild Build State Change"],
    source      = ["aws.codebuild"],
    detail = {
      project-name = [tostring(aws_codebuild_project.pr["${each.value.id}"].name)]
    }
  })
  role_arn = aws_iam_role.cicd.arn
}
resource "aws_cloudwatch_event_target" "lambda" {
  for_each = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  rule     = aws_cloudwatch_event_rule.lambda["${each.value.id}"].id
  arn      = aws_lambda_function.lambda.arn
  input_transformer {
    input_paths = {
      detail-destinationCommit  = "$.detail.destinationCommit",
      detail-pullRequestId      = "$.detail.pullRequestId",
      detail-repositoryNames-0- = "$.detail.repositoryNames[0]",
      detail-revisionId         = "$.detail.revisionId",
      detail-sourceCommit       = "$.detail.sourceCommit"
    }
    input_template = <<EOF
{"sourceIdentifier":<detail-repositoryNames-0->,"sourceVersion":<detail-sourceCommit>,"artifactsOverride":{"type":"NO_ARTIFACTS"},"environmentVariablesOverride":[{"name":"PULL_REQUEST_ID","value":<detail-pullRequestId>,"type":"PLAINTEXT"},{"name":"REPOSITORY_NAME","value":<detail-repositoryNames-0->,"type":"PLAINTEXT"},{"name":"SOURCE_COMMIT","value":<detail-sourceCommit>,"type":"PLAINTEXT"},{"name":"DESTINATION_COMMIT","value":<detail-destinationCommit>,"type":"PLAINTEXT"},{"name":"REVISION_ID","value":<detail-revisionId>,"type":"PLAINTEXT"}]}
EOF 
  }
}

# lambda function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "../lambda_publish_build_result/${local.handler_selection}"
  output_path = "lambda_function_payload.zip"
}
resource "aws_lambda_function" "lambda" {
  filename      = "lambda_function_payload.zip"
  function_name = "${local.resource_prefix}-PullRequestAutomation"
  role          = aws_iam_role.cicd.arn
  handler       = "handler.py"

  runtime = "python3.7"

}

# codebuild - build exeuction environment triggers #TODO
resource "aws_cloudwatch_event_rule" "build" {
  for_each    = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  name        = "${each.value.name}-build"
  description = "initiates build execution environment on PR merge"

  event_pattern = jsonencode({
    resources = [tostring(aws_codecommit_repository.this["${each.value.id}"].arn)]
    detail = {
      event = ["pullRequestMergeStatusUpdated"],
      isMerged = ["True"]
    }
    source = ["aws.codecommit"]
  })
  role_arn = aws_iam_role.cicd.arn
}

resource "aws_cloudwatch_event_target" "build" {
  for_each = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  rule     = aws_cloudwatch_event_rule.build["${each.value.id}"].name
  arn      = aws_codebuild_project.build["${each.value.id}"].arn
}

# codebuild - build phase
resource "aws_codebuild_project" "build" {
  for_each      = { for entry in local.repositories_deploy : "${entry.id}" => entry }
  name          = "${each.value.name}-build"
  description   = "${each.value.name} build execution environment"
  build_timeout = 5
  service_role  = aws_iam_role.cicd.arn #should be the lambda ARN for automation

  artifacts {
    type = "NO_ARTIFACTS"
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
    type            = "CODECOMMIT"
    location        = aws_codecommit_repository.this["${each.value.id}"].clone_url_http
    git_clone_depth = 1
  }

  source_version = "main"

}
