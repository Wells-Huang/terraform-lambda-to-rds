terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- 1. 網路設定 (VPC) ---
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "rds-lambda-example-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "rds-lambda-private-subnet-${count.index}"
  }
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags = {
    Name = "RDS Subnet Group"
  }
}

# VPC Endpoint for Secrets Manager
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true
}

# --- 2. 安全群組 ---
resource "aws_security_group" "rds" {
  name        = "rds-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow traffic to RDS"
}

resource "aws_security_group" "lambda" {
  name        = "lambda-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow traffic from Lambda"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "lambda_to_rds" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda.id
  security_group_id        = aws_security_group.rds.id
}

# --- 3. Secrets Manager: 儲存 RDS 密碼 ---
resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "rds-credentials"
}

resource "aws_secretsmanager_secret_version" "rds_credentials_version" {
  secret_id     = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = "postgres",
    password = var.db_password
  })
}

# --- 4. RDS 資料庫實例 ---
resource "aws_db_instance" "main" {
  identifier           = "example-rds-db"
  engine               = "postgres"
  engine_version       = "16.11"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  username             = jsondecode(aws_secretsmanager_secret_version.rds_credentials_version.secret_string).username
  password             = jsondecode(aws_secretsmanager_secret_version.rds_credentials_version.secret_string).password
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot  = true
}

# --- 5. IAM 角色與政策 ---
# 應用程式 Lambda 的角色
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda-execution-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# 允許 Lambda 讀取 Secret
resource "aws_iam_policy" "lambda_secrets_policy" {
  name   = "lambda-secrets-policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = aws_secretsmanager_secret.rds_credentials.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_secrets_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_secrets_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# --- 6. 應用程式 Lambda ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_layer_version" "psycopg2" {
  filename   = "${path.module}/psycopg2-layer/psycopg2-layer.zip"
  layer_name = "psycopg2-layer"

  compatible_runtimes = ["python3.12"]
}

resource "aws_lambda_function" "db_accessor" {
  function_name = "RDSAccessor"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "func.lambda_handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = 30

  layers = [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SECRET_NAME = aws_secretsmanager_secret.rds_credentials.name
      DB_HOST     = aws_db_instance.main.address
      DB_NAME     = "postgres" # Or your specific DB name
    }
  }
}
