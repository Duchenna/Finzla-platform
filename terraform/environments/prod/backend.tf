terraform {
  backend "s3" {
    bucket         = "finzla-tfstate-<ACCOUNT_ID>"
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "finzla-tflock"
    encrypt        = true
  }
}