terraform {
  required_version = "~> 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
