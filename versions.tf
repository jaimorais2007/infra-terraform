terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Reaproveita o bucket de state das fases anteriores, numa key separada,
  # para não misturar com o state da Fase 3 (auth-service, gateway, database).
  backend "s3" {
    bucket       = "techchallenge-terraform-state-s3"
    key          = "fase4/infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Phase     = "fase4"
      ManagedBy = "terraform"
    }
  }
}
