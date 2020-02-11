data "aws_caller_identity" "default" {
}

data "aws_region" "default" {
}

module "label" {
  source     = "git::https://github.com/cloudposse/terraform-terraform-label.git?ref=tags/0.4.0"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

resource "aws_s3_bucket" "cache_bucket" {
  count         = var.enabled && var.cache_enabled ? 1 : 0
  bucket        = local.cache_bucket_name_normalised
  acl           = "private"
  force_destroy = true
  tags          = module.label.tags

  lifecycle_rule {
    id      = "codebuildcache"
    enabled = true

    prefix = "/"
    tags   = module.label.tags

    expiration {
      days = var.cache_expiration_days
    }
  }
}

resource "random_string" "bucket_prefix" {
  count   = var.enabled ? 1 : 0
  length  = 12
  number  = false
  upper   = false
  special = false
  lower   = true
}

locals {
  cache_bucket_name = "${module.label.id}${var.cache_bucket_suffix_enabled ? "-${join("", random_string.bucket_prefix.*.result)}" : ""}"

  cache_bucket_name_normalised = substr(
    join("-", split("_", lower(local.cache_bucket_name))),
    0,
    min(length(local.cache_bucket_name), 63),
  )

  cache_def = {
    "true" = [
      {
        type     = "S3"
        location = var.enabled && var.cache_enabled ? join("", aws_s3_bucket.cache_bucket.*.bucket) : "none"
      }
    ]
    "false" = []
  }

  cache = local.cache_def[var.cache_enabled ? "true" : "false"]
}

data "aws_secretsmanager_secret_version" "github_access_token" {
  secret_id = "pureweb/build/libraries"
}

resource "aws_codebuild_source_credential" "github_credential" {
  auth_type   = "PERSONAL_ACCESS_TOKEN"
  server_type = "GITHUB"
  token       = jsondecode(data.aws_secretsmanager_secret_version.github_access_token.secret_string)["calgaryscientific-it-personal-github-token"]
}

resource "aws_codebuild_project" "default" {
  count          = var.enabled ? 1 : 0
  name           = module.label.id
  service_role   = "arn:aws:iam::630322998121:role/pw5-build-module-role"
  badge_enabled  = var.badge_enabled
  build_timeout  = var.build_timeout
  source_version = var.branch_hook

  artifacts {
    type = var.artifact_type
  }

  dynamic "cache" {
    for_each = local.cache
    content {
      location = lookup(cache.value, "location", null)
      modes    = lookup(cache.value, "modes", null)
      type     = lookup(cache.value, "type", null)
    }
  }

  environment {
    compute_type                = var.build_compute_type
    image                       = var.build_image
    type                        = "LINUX_CONTAINER"
    privileged_mode             = var.privileged_mode
    image_pull_credentials_type = var.image_pull_credentials_type

    environment_variable {
      name  = "AWS_REGION"
      value = signum(length(var.aws_region)) == 1 ? var.aws_region : data.aws_region.default.name
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = signum(length(var.aws_account_id)) == 1 ? var.aws_account_id : data.aws_caller_identity.default.account_id
    }

    environment_variable {
      name  = "STAGE"
      value = signum(length(var.stage)) == 1 ? var.stage : "UNSET"
    }

    environment_variable {
      name  = "COMPANY_NAME"
      value = "PureWeb"
    }

    environment_variable {
      name  = "TIME_ZONE"
      value = "MST/Edmonton"
    }

    dynamic "environment_variable" {
      for_each = var.environment_variables
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
      }
    }
  }

  source {
    buildspec           = var.buildspec
    type                = var.source_type
    location            = var.source_location
    report_build_status = var.report_build_status

    auth {
      type     = "OAUTH"
      resource = aws_codebuild_source_credential.github_credential.arn
    }
  }

  tags = module.label.tags
}

resource "aws_codebuild_webhook" "default" {
  project_name = join("", aws_codebuild_project.default.*.name)

  filter_group {
    filter {
      type    = "EVENT"
      pattern = var.event_triggers
    }

    filter {
      type    = "HEAD_REF"
      pattern = "refs/heads/${var.branch_hook}"
    }
  }
}

resource "aws_cloudwatch_event_rule" "default" {
  count       = var.enabled && var.enable_notifications ? 1 : 0
  name        = "${aws_codebuild_project.default[count.index].name}-cloudwatch-event-rule"
  description = "Rule for which events should be pushed to sns"

  event_pattern = <<PATTERN
{
  "source": [
    "aws.codebuild"
  ],
  "detail-type": [
    "CodeBuild Build State Change"
  ],
  "detail": {
    "build-status": [
      "FAILED"
    ],
    "project-name": [
      "${aws_codebuild_project.default[count.index].name}"
    ]
  }
}
PATTERN
}

resource "aws_cloudwatch_event_target" "sns_event_target" {
  count     = var.enabled && var.enable_notifications ? 1 : 0
  rule      = aws_cloudwatch_event_rule.default[count.index].name
  target_id = "${aws_codebuild_project.default[count.index].name}-cloudwatch-sns"
  arn       = "arn:aws:sns:us-west-2:630322998121:pw5-build-notifications-topic"

  input_transformer {
    input_paths = {
      build-id = "$.detail.build-id"
      project  = "$.detail.project-name"
      time     = "$.time"
      region   = "$.region"
      status   = "$.detail.build-status"
    }

    input_template = "\"The build <build-id> of CodeBuild project <project> triggered the status <status> at <time>\""
  }
}

resource "aws_cloudwatch_event_target" "lambda_event_target" {
  count     = var.enabled && var.enable_notifications ? 1 : 0
  rule      = aws_cloudwatch_event_rule.default[count.index].name
  target_id = "${aws_codebuild_project.default[count.index].name}-cloudwatch-lambda"
  arn       = "arn:aws:lambda:us-west-2:630322998121:function:codebuild_slackbot_lambda"

  input_transformer {
    input_paths = {
      build-id  = "$.detail.build-id"
      project   = "$.detail.project-name"
      time      = "$.time"
      region    = "$.region"
      status    = "$.detail.build-status"
      initiator = "$.detail.additional-information.initiator"
      source    = "$.detail.additional-information.source-version"
    }

    input_template = <<INPUT_TEMPLATE
{
	"project":<project>,
	"buildId":<build-id>,
	"time":<time>,
	"region":<region>,
	"status":<status>,
	"initiator":<initiator>,
	"source":<source>
}
INPUT_TEMPLATE
  }
}
