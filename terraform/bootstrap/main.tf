terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Short name prefix for resources"
  type        = string
  default     = "openclaw"
}

variable "name_suffix" {
  description = "Short unique suffix to avoid S3 bucket name collisions (e.g. your initials + 2 digits)"
  type        = string
}

variable "bucket_name" {
  description = "Override the S3 bucket name entirely (optional — leave blank to use project_name + name_suffix)"
  type        = string
  default     = ""
}

locals {
  bucket = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-terraform-state-${var.name_suffix}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = local.bucket
    Project = var.project_name
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name    = "terraform-locks"
    Project = "openclaw"
  }
}

output "bucket_name" {
  value = local.bucket
}

output "dynamodb_table" {
  value = aws_dynamodb_table.tflock.name
}
