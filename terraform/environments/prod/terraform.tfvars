# terraform/environments/prod/terraform.tfvars
region         = "eu-west-1"
environment    = "prod"
vpc_cidr       = "10.20.0.0/16" # Different CIDR than dev
image_tag      = "v1.2.0" # Prod uses specific version tags, not "latest"

# Prod specific overrides
desired_count              = 3
log_retention_days         = 365
enable_deletion_protection = true
single_nat_gateway         = false