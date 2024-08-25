###############################################################################
# Provider
###############################################################################
terraform {
  backend "s3" {
    bucket = "XXXXXXXXXXXX-bucket-state-file"
    key    = "terraform.eks.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
}

###############################################################################
# Data
###############################################################################
data "aws_caller_identity" "current" {}

###############################################################################
# VPC
###############################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "${var.app_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  intra_subnets   = ["10.0.104.0/24", "10.0.105.0/24", "10.0.106.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  private_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  public_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}

###############################################################################
# KMS
###############################################################################
module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "3.1.0"

  description = "EKS Cluster"
  key_usage   = "ENCRYPT_DECRYPT"

  # Policy
  key_administrators                 = [data.aws_caller_identity.current.arn]
  key_owners                         = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling  = ["arn:aws:iam::${var.aws_account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]

  # Aliases
  aliases = ["eks/${var.app_name}"]

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}

###############################################################################
# EKS
###############################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.23.0"

  cluster_name    = var.app_name
  cluster_version = "1.30"

  cluster_endpoint_public_access  = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = ["t3.medium"]
  }

  eks_managed_node_groups = {
    "${var.app_name}-ng" = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 10
      desired_size = 2

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            kms_key_id            = module.kms.key_arn
            delete_on_termination = true
          }
        }
      }

    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true

  create_kms_key = false
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = module.kms.key_arn
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

###############################################################################
# EBS CSI
###############################################################################
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.44.0"

  role_name = "${var.app_name}-ebs-csi"

  attach_ebs_csi_policy = true
  ebs_csi_kms_cmk_ids   = [module.kms.key_arn]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = "1.30"
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-ebs-csi-driver"

  addon_version               = data.aws_eks_addon_version.ebs_csi.version
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn    = module.ebs_csi_irsa_role.iam_role_arn

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

###############################################################################
# Storage Class
###############################################################################
resource "kubectl_manifest" "ebs_csi_default_storage_class" {
  yaml_body = <<-YAML
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    annotations:
      storageclass.kubernetes.io/is-default-class: "true"
    name: gp3-default
  provisioner: ebs.csi.aws.com
  reclaimPolicy: Delete
  volumeBindingMode: WaitForFirstConsumer
  allowVolumeExpansion: true
  parameters:
    type: gp3  
    fsType: ext4
    encrypted: "true"
    kmsKeyId: "arn:aws:kms:us-east-1:770236806245:key/30d24e00-0d3b-417f-8bfc-b7416d8a4703"
  YAML
}