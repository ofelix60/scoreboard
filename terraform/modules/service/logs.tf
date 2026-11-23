
# --- Logs ---------------------------------------------------------------------
# The container's stdout (one JSON line per request) arrives here through
# Docker's awslogs driver. Terraform owns the group so retention is set: a
# group the driver creates on its own never expires.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/app"
  retention_in_days = var.log_retention_days
}
