terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ⚠️  Backend blocks do not support variable interpolation.
  # In CI, the bucket is overridden via -backend-config flags (see workflow files).
  # For local runs, either edit this block directly or use a .tfbackend file.
  # The bucket name must match: "<project_name>-terraform-state-<name_suffix>"
  backend "s3" {
    bucket         = "openclaw-terraform-state-YOURSUFFIX"
    key            = "openclaw/terraform.tfstate"
    region         = "us-east-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Data: latest Ubuntu 24.04 LTS AMI
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Networking: default VPC + first available subnet
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "openclaw" {
  name        = "${var.project_name}-sg"
  description = "${var.project_name} gateway - SSH from allowlisted IP, HTTP/S from anywhere"
  vpc_id      = data.aws_vpc.default.id

  # SSH — your IP only
  ingress {
    description = "SSH from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # HTTP — needed for ACME challenge redirect
  ingress {
    description = "HTTP (ACME redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = "openclaw"
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "openclaw" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = tolist(sort(data.aws_subnets.default.ids))[0]
  vpc_security_group_ids = [aws_security_group.openclaw.id]
  iam_instance_profile   = aws_iam_instance_profile.openclaw_ec2.name
  ebs_optimized          = true

  user_data = templatefile("${path.module}/user_data.sh", {
    domain       = var.domain
    project_name = var.project_name
    name_suffix  = var.name_suffix
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = {
    Name    = "openclaw"
    Project = "openclaw"
  }
}

# ---------------------------------------------------------------------------
# Elastic IP
# ---------------------------------------------------------------------------
resource "aws_eip" "openclaw" {
  instance = aws_instance.openclaw.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = "openclaw"
  }
}

# ---------------------------------------------------------------------------
# DNS: Route 53 A record → EIP
# ---------------------------------------------------------------------------
data "aws_route53_zone" "main" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "openclaw" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.openclaw.public_ip]
}

# ---------------------------------------------------------------------------
# AWS Budget: monthly cost alert
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "openclaw_monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# ---------------------------------------------------------------------------
# S3 backup bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "openclaw_backups" {
  bucket = "${var.project_name}-backups-${var.name_suffix}"

  tags = {
    Name    = "${var.project_name}-backups"
    Project = "openclaw"
  }
}

resource "aws_s3_bucket_versioning" "openclaw_backups" {
  bucket = aws_s3_bucket.openclaw_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "openclaw_backups" {
  bucket = aws_s3_bucket.openclaw_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "openclaw_backups" {
  bucket                  = aws_s3_bucket.openclaw_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudWatch metrics for backup monitoring — enables NumberOfObjects and TotalSize metrics
resource "aws_s3_bucket_metric" "openclaw_backups" {
  bucket = aws_s3_bucket.openclaw_backups.id
  name   = "EntireBucket"
}

# ---------------------------------------------------------------------------
# IAM role + instance profile for EC2 → S3 backup access
# ---------------------------------------------------------------------------
resource "aws_iam_role" "openclaw_ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Name    = "${var.project_name}-ec2-role"
    Project = "openclaw"
  }
}

resource "aws_iam_role_policy" "openclaw_backups" {
  name = "${var.project_name}-s3-backups"
  role = aws_iam_role.openclaw_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.openclaw_backups.arn,
        "${aws_s3_bucket.openclaw_backups.arn}/*"
      ]
    }]
  })
}

# Scoped to the specific backup bucket only
resource "aws_iam_role_policy" "openclaw_cloudwatch_agent" {
  name = "${var.project_name}-cloudwatch-agent"
  role = aws_iam_role.openclaw_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "ec2:DescribeVolumes",
        "ec2:DescribeTags"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "openclaw_ssm" {
  role       = aws_iam_role.openclaw_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "openclaw_ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.openclaw_ec2.name
}

# ---------------------------------------------------------------------------
# SSH Key Pair — imported from existing key
# ---------------------------------------------------------------------------

# The openclaw-ssh key pair is imported from an existing key.
# Set the openclaw_ssh_public_key variable in your tfvars file with the
# content of your public key file (e.g., ~/.ssh/openclaw-ssh.pub)
resource "aws_key_pair" "openclaw_ssh" {
  key_name   = "openclaw-ssh"
  public_key = var.openclaw_ssh_public_key

  # AWS does not return the public key material on import, so Terraform will
  # always see a diff and attempt destroy+recreate. Ignore it after import.
  lifecycle {
    ignore_changes = [public_key]
  }

  tags = {
    Name    = "openclaw-ssh"
    Project = "openclaw"
  }
}


