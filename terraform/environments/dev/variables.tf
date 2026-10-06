variable "region"          { type = string default = "eu-west-1" }
variable "environment"     { type = string default = "dev" }
variable "vpc_cidr"        { type = string default = "10.10.0.0/16" }
variable "public_subnets"  { type = list(string) default = ["10.10.0.0/24","10.10.1.0/24"] }
variable "private_subnets" { type = list(string) default = ["10.10.10.0/24","10.10.11.0/24"] }
variable "certificate_arn" { type = string }
variable "kms_key_arn"     { type = string }
variable "app_secret_arn"  { type = string }
variable "image_tag"       { type = string default = "latest" }