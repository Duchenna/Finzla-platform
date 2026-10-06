output "alb_dns_name"  { value = module.alb.alb_dns_name }
output "ecr_repo_url"  { value = module.ecr.repository_url }
output "ecs_cluster"   { value = "${local.name}-cluster" }
output "ecs_service"   { value = "${local.name}-svc" }