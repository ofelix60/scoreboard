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
