data "aws_caller_identity" "default" {
}

data "aws_region" "default" {
}

module "label" {
  source 	 = "git::https://github.com/cloudposse/terraform-terraform-label.git?ref=tags/0.4.0"
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

resource "aws_iam_role" "default" {
  count                 = var.enabled ? 1 : 0
  name                  = module.label.id
  assume_role_policy    = data.aws_iam_policy_document.role.json
  force_detach_policies = "true"
}

data "aws_iam_policy_document" "role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_policy" "default" {
  count  = var.enabled ? 1 : 0
  name   = module.label.id
  path   = "/service-role/"
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_iam_policy" "default_cache_bucket" {
  count  = var.enabled && var.cache_enabled ? 1 : 0
  name   = "${module.label.id}-cache-bucket"
  path   = "/service-role/"
  policy = join("", data.aws_iam_policy_document.permissions_cache_bucket.*.json)
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid = ""

    actions = [
	  "ecr:*",
      "ecs:RunTask",
      "iam:PassRole",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
	  "s3:*",
      "ssm:GetParameters",
    ]

    effect = "Allow"

    resources = [
      "*",
    ]
  }
}

data "aws_iam_policy_document" "permissions_cache_bucket" {
  count = var.enabled && var.cache_enabled ? 1 : 0

  statement {
    sid = ""

    actions = [
      "s3:*",
    ]

    effect = "Allow"

    resources = [
      join("", aws_s3_bucket.cache_bucket.*.arn),
      "${join("", aws_s3_bucket.cache_bucket.*.arn)}/*",
    ]
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  count      = var.enabled ? 1 : 0
  policy_arn = join("", aws_iam_policy.default.*.arn)
  role       = join("", aws_iam_role.default.*.id)
}

resource "aws_iam_role_policy_attachment" "default_cache_bucket" {
  count      = var.enabled && var.cache_enabled ? 1 : 0
  policy_arn = join("", aws_iam_policy.default_cache_bucket.*.arn)
  role       = join("", aws_iam_role.default.*.id)
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
  count         = var.enabled ? 1 : 0
  name          = module.label.id
  service_role  = join("", aws_iam_role.default.*.arn)
  badge_enabled = var.badge_enabled
  build_timeout = var.build_timeout

  artifacts {
    type 	  = var.artifact_type
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
    compute_type    			= var.build_compute_type
    image           			= var.build_image
    type            			= "LINUX_CONTAINER"
    privileged_mode 			= var.privileged_mode
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
      name = "TIME_ZONE"
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
      type = "EVENT"
      pattern = var.event_triggers
    }
 
    filter {
      type = "HEAD_REF"   
      pattern = "refs/heads/${var.branch_hook}"
    }
  }
}


