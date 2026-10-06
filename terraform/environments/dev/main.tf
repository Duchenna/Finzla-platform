terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "finzla-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Define local values for naming conventions
locals {
  name = "finzla-${var.environment}"
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  single_nat_gateway = true   # dev cost saving
}

# Call the ECR Module
module "ecr" {
  source = "../../modules/ecr"
  name   = local.name
}

# Call the ALB Module
module "alb" {
  source            = "../../modules/alb"
  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  certificate_arn   = var.certificate_arn
  environment       = var.environment
}

module "iam" {
  source          = "../../modules/iam"
  name            = local.name
  account_id      = data.aws_caller_identity.current.account_id
  app_secret_arn  = var.app_secret_arn
  kms_key_arn     = var.kms_key_arn
  log_group_arn   = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name}"
}

#  Call the ECS Module (Cluster and Service)
module "ecs" {
  source                 = "../../modules/ecs"
  name                   = local.name
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  alb_security_group_id  = module.alb.alb_security_group_id
  target_group_arn       = module.alb.target_group_arn
  execution_role_arn     = module.iam.task_execution_role_arn
  task_role_arn          = module.iam.task_role_arn
  image_uri              = module.ecr.repository_url
  image_tag              = var.image_tag
  environment            = var.environment
  region                 = var.region
  desired_count          = 1
  log_retention_days     = 14
  kms_key_arn            = var.kms_key_arn
  app_secret_arn         = var.app_secret_arn
}

module "observability" {
  source                  = "../../modules/observability"
  name                    = local.name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  service_name            = "${local.name}-svc"
  cluster_name            = "${local.name}-cluster"
  kms_key_arn             = var.kms_key_arn
}

data "aws_caller_identity" "current" {}