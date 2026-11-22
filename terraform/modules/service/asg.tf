# --- Instances ----------------------------------------------------------------

data "aws_region" "current" {}
data "aws_default_tags" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 only. Hop limit 2 so a container can reach the instance's
  # credentials too (the docker bridge adds a hop).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # t4g defaults to "unlimited", which bills for surplus CPU credits.
  credit_specification {
    cpu_credits = "standard"
  }

  # The AMI's root volume is unencrypted by default. Size comes from the AMI.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region        = data.aws_region.current.region
    registry      = split("/", aws_ecr_repository.app.repository_url)[0]
    image         = local.image
    app_port      = var.app_port
    environment   = var.environment
    db_host       = aws_db_instance.this.address
    db_port       = aws_db_instance.this.port
    db_name       = aws_db_instance.this.db_name
    db_secret_arn = aws_db_instance.this.master_user_secret[0].secret_arn
  }))

  # default_tags don't reach instances an ASG launches; tag them explicitly.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.aws_default_tags.current.tags, { Name = "${var.name}-app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(data.aws_default_tags.current.tags, { Name = "${var.name}-app" })
  }

  update_default_version = true
}

resource "aws_autoscaling_group" "app" {
  name                = var.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.app.arn]

  # EC2, not ELB. ELB would replace every instance when the database blips,
  # because /readyz fails on all of them at once. A wedged-but-running
  # process is the gap this leaves; the UnHealthyHostCount alarm covers it.
  health_check_type         = "EC2"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Without this, a launch template change applies cleanly and running
  # instances keep the old user_data forever. 100/200 = launch the
  # replacement before terminating the old one, so a fleet of 1 never hits 0.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }
  # New instances read the DB secret at boot. Nothing in the launch template
  # references this policy, so without this the refresh can start before the
  # permission exists.
  depends_on = [aws_iam_role_policy.app_db_secret]
}

# The ASG won't replace a wedged-but-running instance (EC2 health checks).
# This alarm is how someone finds out instead.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "A target has failed /readyz for 5 minutes. The ASG will not replace it."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}
