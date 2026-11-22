module "service" {
  source = "../../modules/service"

  name = "scoreboard-dev"
}

output "service" {
  description = "Everything the module returns."
  value       = module.service
}
