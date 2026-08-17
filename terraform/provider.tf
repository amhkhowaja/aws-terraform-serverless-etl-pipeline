terraform {
    required_version = ">= 1.5"

    required_providers {
        aws     = { source = "hashicorp/aws", version = "~> 6.0" }
        archive = { source = "hashicorp/archive", version = "~> 2.4" }
        random  = { source = "hashicorp/random", version = "~> 3.6" }
    }
}

locals {
    # have two envs floci(local) and aws(dev) 
    is_local = var.aws_endpoint_url != ""
    name_prefix = "${var.project_name}-${var.environment}"
    
    common_tags = merge(var.tags, {
        Project = var.project_name
        Environment = var.environment
        ManagedBy = "terraform"
    })
}

provider "aws" {
  region = var.aws_region
  access_key = local.is_local ? "test" : null
  secret_key = local.is_local ? "test" : null

  skip_credentials_validation = local.is_local
  skip_metadata_api_check = local.is_local
  skip_requesting_account_id = local.is_local
  s3_use_path_style = local.is_local # used for floci emulation testing

  dynamic "endpoints" {
    for_each = local.is_local ? [1] : []
    content {
        s3 = var.aws_endpoint_url
        sqs = var.aws_endpoint_url
        lambda = var.aws_endpoint_url
        iam = var.aws_endpoint_url
        sts = var.aws_endpoint_url
        logs = var.aws_endpoint_url
    }
  }
}