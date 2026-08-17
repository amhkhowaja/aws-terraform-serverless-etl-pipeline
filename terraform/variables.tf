variable "project_name" {
  default = "car-sales"
}

variable "environment" {
  default = "dev"
}

variable "aws_region" {
  default = "eu-central-1"
}

variable "aws_endpoint_url" {
  default = "" //for floci emulation i used : http://localhost:4566
}

variable "pandas_layer_arn" {
  default = ""
}

# Lambda

variable "lambda_runtime" {
  default = "python3.13"
}

variable "lambda_memory_mb" {
  default = 512
}

variable "lambda_timeout_second" {
  default = 60
}

# S3
variable "curated_object_prefix" {
  default = "curated_object"
}

variable "landing_prefix" {
  default = "incoming/"
}

# SQS
variable "sqs_max_receive_count" {
  default = 3
}

variable "sqs_visibility_timeout_seconds" {
  default = 90
}

# CloudWatch
variable "log_retention_days" {
  default = 14
}

variable "tags" {
    #  extra tags merged into every resource
  default = {}
}
