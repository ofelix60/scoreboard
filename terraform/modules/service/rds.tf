# --- Database ----------------------------------------------------------------
# Private subnets only (no route out), reachable only from the app SG.
# RDS generates the master password and keeps it in Secrets Manager, so it
# never passes through Terraform and never lands in the state file.

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = var.name }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = "16" # matches compose; RDS picks the latest 16.x minor
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "scoreboard"
  username = "scoreboard"

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # 1 day keeps automated backups (and point-in-time recovery) on; 0 turns them off.
  backup_retention_period = 1

  # Demo settings, wrong for production: destroy without a final snapshot,
  # and no deletion protection. Named in the README.
  skip_final_snapshot = true
  deletion_protection = false

  apply_immediately = true

  tags = { Name = var.name }
}
