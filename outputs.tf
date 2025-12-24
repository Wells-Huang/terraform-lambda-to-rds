output "lambda_function_name" {
  value = aws_lambda_function.db_accessor.function_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "secret_name" {
  value = aws_secretsmanager_secret.rds_credentials.name
}
