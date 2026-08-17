locals{
    function_name = "${local.name_prefix}-preprocess"   
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "landing" {
  bucket = "${local.name_prefix}-landing-${random_id.suffix.hex}"  
  force_destroy = true
  tags = local.common_tags
}

resource "aws_s3_bucket" "curated" {
  bucket = "${local.name_prefix}-curated-${random_id.suffix.hex}"
  force_destroy = true                                                                                                                
  tags = local.common_tags 
}

resource "aws_sqs_queue" "dlq" {
  name = "${local.name_prefix}-ingest-dlq"
  tags = local.common_tags
}

resource "aws_sqs_queue" "ingest" {
  name = "${local.name_prefix}-ingest" 
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount = var.sqs_max_receive_count
  })

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "ingest" {
  queue_url = aws_sqs_queue.ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Principal = {Service = "s3.amazonaws.com"}
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.ingest.arn
        Condition = {
            ArnLike = {
                "aws:SourceArn" = aws_s3_bucket.landing.arn
            }
        }
    }]
  })

}

resource "aws_iam_role" "lambda" {
  name = "${local.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_s3_bucket_notification" "landing" {
  bucket = aws_s3_bucket.landing.id

  queue {
    queue_arn = aws_sqs_queue.ingest.arn
    events = ["s3:ObjectCreated:*"]
    filter_prefix = var.landing_prefix
    filter_suffix = ".csv"
  }
  depends_on = [ aws_sqs_queue_policy.ingest ]
}

resource "aws_iam_role_policy" "lambda" {                                                                                                                        
  name = "${local.function_name}-policy"                                                                                                                         
  role = aws_iam_role.lambda.id                                                                                                                                  
                                                                                                                                                                 
  policy = jsonencode({                                                                                                                                          
    Version = "2012-10-17"                                                                                                                                       
    Statement = [                                                                                                                                              
      {                                                                                                                                                          
        Effect   = "Allow"                                                                                                                                       
        Action   = ["s3:GetObject"]                                                                                                                              
        Resource = "${aws_s3_bucket.landing.arn}/*"                                                                                                              
      },                                                                                                                                                         
      {                                                                                                                                                          
        Effect   = "Allow"                                                                                                                                       
        Action   = ["s3:PutObject"]                                                                                                                              
        Resource = "${aws_s3_bucket.curated.arn}/${var.curated_object_prefix}/*"                                                                                 
      },                                                                                                                                                         
      {                                                                                                                                                          
        Effect = "Allow"                                                                                                                                         
        Action = [                                                                                                                                               
          "sqs:ReceiveMessage",                                                                                                                                  
          "sqs:DeleteMessage",                                                                                                                                   
          "sqs:GetQueueAttributes",                                                                                                                              
        ]                                                                                                                                                        
        Resource = aws_sqs_queue.ingest.arn                                                                                                                      
      },                                                                                                                                                         
      {                                                                                                                                                          
        Effect = "Allow"                                                                                                                                         
        Action = [                                                                                                                                               
          "logs:CreateLogGroup",                                                                                                                                 
          "logs:CreateLogStream",                                                                                                                                
          "logs:PutLogEvents",                                                                                                                                   
        ]                                                                                                                                                        
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/${local.function_name}:*"                                                                             
      },                                                                                                                                                         
    ]                                                                                                                                                            
  })                                                                                                                                                             
}

resource "aws_cloudwatch_log_group" "lambda" {
  name = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags = local.common_tags
}

data "archive_file" "lambda" {
  type = "zip"
  source_dir = "${path.module}/build/package"
  output_path = "${path.module}/build/process_data.zip"  
}

resource "aws_lambda_function" "preprocess" {
  function_name = local.function_name
  role = aws_iam_role.lambda.arn
  handler = "process_data.handler"
  runtime = var.lambda_runtime
  architectures = ["arm64"]
  filename = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

    # aws vs floci
  layers = var.pandas_layer_arn != "" ? [var.pandas_layer_arn] : []
  memory_size = var.lambda_memory_mb
  timeout = var.lambda_timeout_second

  environment {
    variables = {
      LANDING_ZONE_BUCKET = aws_s3_bucket.landing.id
      CURATED_ZONE_BUCKET = aws_s3_bucket.curated.id
      CURATED_OBJECT_PREFIX = var.curated_object_prefix
    }
  }

  depends_on = [ aws_iam_role_policy.lambda, aws_cloudwatch_log_group.lambda ]
  tags = local.common_tags
}

resource "aws_lambda_event_source_mapping" "ingest" {
    event_source_arn = aws_sqs_queue.ingest.arn
    function_name = aws_lambda_function.preprocess.arn
    batch_size = 1
  
}