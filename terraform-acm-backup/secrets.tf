resource "aws_secretsmanager_secret" "oadp_credentials" {
  name                    = var.secrets_manager_secret_name
  description             = "OADP credentials for ACM backup on ${var.cluster_name}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "oadp_credentials" {
  secret_id = aws_secretsmanager_secret.oadp_credentials.id
  secret_string = jsonencode({
    role_arn = aws_iam_role.oadp.arn
  })
}
