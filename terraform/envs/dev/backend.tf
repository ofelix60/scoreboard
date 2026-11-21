terraform {
  required_version = ">= 1.11"

  backend "s3" {
    bucket       = "scoreboard-tfstate-748076390329"
    key          = "dev/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = {
      Project   = "scoreboard"
      ManagedBy = "terraform"
      Env       = "dev"
    }
  }
}
