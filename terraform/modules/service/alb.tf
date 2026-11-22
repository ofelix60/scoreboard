# --- Load balancer ------------------------------------------------------------
# The ALB routes on /readyz (readiness): an instance that can't reach the
# database leaves rotation. The ASG does NOT use this check; see asg.tf.

resource "aws_lb" "app" {
  name               = var.name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Reject requests with malformed headers instead of passing them to the app.
  drop_invalid_header_fields = true

  tags = { Name = var.name }
}

resource "aws_lb_target_group" "app" {
  name     = var.name
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  # Default is 300s: a scale-in or refresh would hang for 5 minutes per instance.
  deregistration_delay = 30

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = var.name }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
