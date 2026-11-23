
# --- Instance role ------------------------------------------------------------
# The app instances can: be reached over SSM, pull from this module's ECR
# repository, read this module's database secret, write to this
# module's log group, and finish its own launch lifecycle action. Nothing else.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app_ecr_pull" {
  # GetAuthorizationToken can't be scoped to a repository; AWS only accepts "*".
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "app_ecr_pull" {
  name   = "ecr-pull"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_ecr_pull.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

# RDS created this secret. The role can read this one secret and no other.
# No kms:Decrypt needed: the secret uses the AWS-managed aws/secretsmanager key.
data "aws_iam_policy_document" "app_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "app_db_secret" {
  name   = "db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_db_secret.json
}

# Write to this module's log group only. Terraform creates the group, so no
# logs:CreateLogGroup. Streams live inside the group, hence the ":*".
data "aws_iam_policy_document" "app_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app_logs" {
  name   = "logs"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_logs.json
}

data "aws_caller_identity" "current" {}

# user_data reports "ready" (or "give up") for its own launch. The ARN is built
# from the ASG's name, not aws_autoscaling_group.app.arn: the ASG depends on
# this policy, so referencing the ASG here would be a cycle. The * is the ASG's
# generated ID; the name still pins it to this one group.
data "aws_iam_policy_document" "app_lifecycle" {
  statement {
    actions = ["autoscaling:CompleteLifecycleAction"]
    resources = [
      "arn:aws:autoscaling:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name}",
    ]
  }
}

resource "aws_iam_role_policy" "app_lifecycle" {
  name   = "lifecycle"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_lifecycle.json
}
