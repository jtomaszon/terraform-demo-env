variable "aws_region" {
  description = "Region for the Demo Environment"
  default = "sa-east-1"
}

# Define SSH key pair for our instances
variable "key_path" {
  description = "SSH Key path"
  default = "~/.ssh/terraform-demo-env.pem"
}

variable "instance_type" {
  type = string
}
variable "elastic_app" {
  type = string
}
variable "beanstalk_app_env" {
  type = string
}
variable "solution_stack_name" {
  type = string
}
variable "tier" {
  type = string
}