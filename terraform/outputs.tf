output "landing_bucket" {
  value = aws_s3_bucket.landing.id
}

output "curated_bucket" {
  value = aws_s3_bucket.curated.id
}

output "curated_object_prefix" {
  value = var.curated_object_prefix
}

output "landing_prefix" {
  value = var.landing_prefix
}

output "ingest_queue_url" {
  value = aws_sqs_queue.ingest.id
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.id
}

output "function_name" {
  value = aws_lambda_function.preprocess.function_name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.lambda.name
}

output "upload_command" {
  value = "aws s3 cp ml_sample_data_snapsoft.csv s3://${aws_s3_bucket.landing.id}/${var.landing_prefix}"
}
