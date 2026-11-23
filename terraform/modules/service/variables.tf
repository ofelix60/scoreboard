variable "name" {
  description = "Prefix for every resource name, e.g. myapp-staging. Must be unique per account."
  type        = string
}

variable "vpc_cidr" {
  description = "Address range for the whole VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many availability zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "The ALB and the RDS subnet group both require at least two availability zones."
  }
}

variable "app_port" {
  description = "Port the app container listens on."
  type        = number
  default     = 8000
}

variable "environment" {
  description = "Environment name the app logs as (its ENV variable)."
  type        = string
}

variable "image_tag" {
  description = "Tag of the image in this module's ECR repository to run. A git SHA."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must be arm64 (Graviton): the image is built for linux/arm64."
  type        = string
  default     = "t4g.micro"
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 2
}

variable "desired_capacity" {
  type    = number
  default = 1
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "log_retention_days" {
  description = "Days to keep app logs in CloudWatch."
  type        = number
  default     = 7
}
