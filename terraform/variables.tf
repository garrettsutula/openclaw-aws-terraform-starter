variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "my_ip" {
  description = "Your public IP in CIDR notation (e.g. 1.2.3.4/32) — used to allowlist SSH"
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "domain" {
  description = "Domain or subdomain to point at the instance (e.g. openclaw.example.com)"
  type        = string
}

variable "hosted_zone_name" {
  description = "Name of the existing Route 53 hosted zone (e.g. example.com)"
  type        = string
}

variable "project_name" {
  description = "Short name used to prefix AWS resources (S3 buckets, IAM roles, security groups)"
  type        = string
  default     = "openclaw"
}

variable "name_suffix" {
  description = "Short unique suffix to avoid S3 bucket name collisions (e.g. your initials + 2 digits: 'gs08')"
  type        = string
}

variable "budget_alert_email" {
  description = "Email address to notify when monthly cost exceeds the budget threshold"
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget threshold in USD — alert fires when forecasted cost exceeds this"
  type        = number
  default     = 25
}

variable "openclaw_ssh_public_key" {
  description = "Public key content for the openclaw-ssh key pair. Set this in your tfvars file with the content of your ~/.ssh/openclaw-ssh.pub file."
  type        = string
  sensitive   = true
}
