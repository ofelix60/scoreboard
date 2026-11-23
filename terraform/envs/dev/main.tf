module "service" {
  source = "../../modules/service"

  name        = "scoreboard-dev"
  environment = "dev"
  image_tag = "fb5b573"
}

output "service" {
  description = "Everything the module returns."
  value       = module.service
}

output "url" {
  value = "http://${module.service.alb_dns_name}"
}
