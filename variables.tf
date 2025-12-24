variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "db_password" {
  description = "RDS master user password"
  type        = string
  sensitive   = true
}
