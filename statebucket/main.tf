###############################################################################
# Provider
###############################################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
}

###############################################################################
# S3 Bucket
###############################################################################
resource "aws_s3_bucket" "state" {
  bucket = "${var.aws_account_id}-bucket-state-file"

  tags = {
    Environment = var.environment
  }
}
