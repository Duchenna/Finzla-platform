variable "name"                 { type = string }
variable "vpc_cidr"             { type = string }
variable "public_subnets"       { type = list(string) }
variable "private_subnets"      { type = list(string) }
variable "single_nat_gateway"   { type = bool  default = false }
variable "tags"                 { type = map(string) default = {} }
