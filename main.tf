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
resource "random_id" "secret_suffix" {
  byte_length = 4
  keepers = {
    # 只要這個值不變，suffix 就不會變。
    # 如果想強制換名，可以改這個值
    version = "1"
  }
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "rds-credentials-${random_id.secret_suffix.hex}"
}

resource "aws_secretsmanager_secret_version" "rds_credentials_version" {
  secret_id     = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.main.address
    username = "postgres"
    password = var.db_password
    dbname   = "postgres"
    port     = 5432
  })
}

# --- 4. RDS 資料庫實例 ---
resource "aws_db_instance" "main" {
  identifier           = "example-rds-db"
  engine               = "postgres"
  engine_version       = "16.11"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  username             = "postgres"
  password             = var.db_password
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot  = true

  # 忽略密碼變更，因為之後會由 Secrets Manager 進行輪換
  lifecycle {
    ignore_changes = [password]
  }
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

# --- 6. 應用程式 Lambda ---
# (Existing Lambda config...)
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
      # 使用 App User Secret
      SECRET_NAME = aws_secretsmanager_secret.app_db_credentials.name
      DB_HOST     = aws_db_instance.main.address
      DB_NAME     = "postgres"
    }
  }
}

# 6.5 Admin Utility Lambda (用於執行初始化腳本)
resource "aws_lambda_function" "rds_admin" {
  function_name = "RDSAdmin"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "admin.lambda_handler"
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
      # 指向 Admin Secret 以便擁有 CREATE USER 權限
      SECRET_NAME = aws_secretsmanager_secret.rds_credentials.name
    }
  }
}

# --- 7. Credential Rotation (使用自訂 Lambda) ---

# 7.0 Rotation Lambda Function (共用程式碼)
# 定義 Rotation Lambda，包含 Single 和 Multi 的 Handler
resource "aws_lambda_function" "rotation_function" {
  function_name = "postgres-rotation"
  role          = aws_iam_role.lambda_exec_role.arn # 重用 Role (需補強權限)
  handler       = "rotation.handler_single" # 預設 Single，但實際上會部署兩個或使用 override
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = 30

  # 使用與 App Lambda 相同的 layer
  layers = [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }
}

# 為了同時支援 Single 和 Multi，我們可以建立兩個 Alias 或者兩個 Function。
# 這裡簡單起見，建立兩個指向同一程式碼但 Handler 不同的 Function，
# 或者只建立一個 Function，但這裡 handler 是固定的。
# 更好的做法：部署兩個 Function 資源，指向同一個 zip。

resource "aws_lambda_function" "rotation_single" {
  function_name = "postgres-rotation-single"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "rotation.handler_single"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = 30
  layers        = [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }
}

resource "aws_lambda_function" "rotation_multi" {
  function_name = "postgres-rotation-multi"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "rotation.handler_multi"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = 30
  layers        = [aws_lambda_layer_version.psycopg2.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }
}

# 必須允許 Secrets Manager 呼叫 these Lambdas
resource "aws_lambda_permission" "allow_secrets_manager_single" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation_single.function_name
  principal     = "secretsmanager.amazonaws.com"
}

resource "aws_lambda_permission" "allow_secrets_manager_multi" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation_multi.function_name
  principal     = "secretsmanager.amazonaws.com"
}

# 7.1 Admin Rotation (使用 Single Rotation Lambda)
resource "aws_secretsmanager_secret_rotation" "admin_rotation" {
  secret_id           = aws_secretsmanager_secret.rds_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotation_single.arn

  rotation_rules {
    automatically_after_days = 30
  }
}

# 7.2 App User Rotation (使用 Multi Rotation Lambda)

# 建立 App User 的 Secret
resource "aws_secretsmanager_secret" "app_db_credentials" {
  name = "app-db-credentials-${random_id.secret_suffix.hex}"
}

# App User 初始密碼
resource "aws_secretsmanager_secret_version" "app_db_credentials_version" {
  secret_id     = aws_secretsmanager_secret.app_db_credentials.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.main.address
    username = "app_user"
    password = "InitialPassword123!"
    dbname   = "postgres"
    port     = 5432
    masterarn = aws_secretsmanager_secret.rds_credentials.arn
  })
}

# 設定 App User 輪換
resource "aws_secretsmanager_secret_rotation" "app_rotation" {
  secret_id           = aws_secretsmanager_secret.app_db_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotation_multi.arn

  rotation_rules {
    automatically_after_days = 30
  }
}

# 更新權限：允許應用程式 Lambda 讀取新的 App Secret
resource "aws_iam_policy" "lambda_app_secrets_policy" {
  name   = "lambda-app-secrets-policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = aws_secretsmanager_secret.app_db_credentials.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_app_secrets_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_app_secrets_policy.arn
}

# 重要：Rotation Lambda 需要額外權限 (PutSecretValue, DescribeSecret, GetRandomPassword)
# 這些權限目前在 lambda_secrets_policy 中可能只有 GetSecretValue
resource "aws_iam_policy" "rotation_lambda_policy" {
  name   = "rotation-lambda-policy"
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:GetRandomPassword"
        ],
        Effect   = "Allow",
        Resource = "*" # 簡化起見，允許存取所有 secrets。生產環境應限制 resource
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rotation_lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.rotation_lambda_policy.arn
}

