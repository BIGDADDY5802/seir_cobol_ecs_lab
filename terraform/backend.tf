terraform {
  backend "s3" {
    key          = "seir-module3-lab01/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
