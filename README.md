# openclaw-aws-terraform-starter

Terraform + GitHub Actions for deploying [OpenClaw](https://github.com/openclaw/openclaw) on AWS EC2 with security hardening and automatic TLS.

**Estimated cost:** ~$20/month (t3.small + 20GB gp3 + Elastic IP)

## Prerequisites

- AWS account with permissions for EC2, VPC, EIP, S3, DynamoDB, Route 53, and Budgets
- An existing EC2 key pair for SSH access
- A Route 53 hosted zone for your domain
- Terraform ≥ 1.6 (for the local bootstrap step only)

## Getting Started

### 1. Bootstrap remote state (local)

Fork this repo, clone it, then provision the S3 bucket and DynamoDB table for Terraform remote state:

```bash
cd terraform/bootstrap/
terraform init
terraform apply -var="name_suffix=YOUR_SUFFIX"
# YOUR_SUFFIX: short unique string, e.g. initials + 2 digits (gs08)
```

Then update the `bucket` value in `terraform/main.tf` to match:

```hcl
backend "s3" {
  bucket = "openclaw-terraform-state-YOUR_SUFFIX"
  ...
}
```

### 2. Configure GitHub Actions

Add these secrets to your fork (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_REGION` | e.g. `us-east-2` |
| `NAME_SUFFIX` | Must match your bootstrap suffix |
| `OPERATOR_IP` | Your public IP in CIDR, e.g. `1.2.3.4/32` |
| `EC2_KEY_NAME` | Name of an existing EC2 key pair |
| `OPENCLAW_DOMAIN` | e.g. `openclaw.example.com` |
| `HOSTED_ZONE_NAME` | Route 53 hosted zone, e.g. `example.com` |
| `BUDGET_ALERT_EMAIL` | Email for cost alert notifications |

Then create a **`production`** environment (**Settings → Environments → New environment**) and configure it to require manual approval before the apply workflow runs.

Push or open a PR to `main` — the plan workflow runs on PRs, apply runs on merge (with manual approval gate).

### 3. Onboard OpenClaw

Once the instance is up:

```bash
ssh -i ~/.ssh/<your-key>.pem openclaw@<elastic-ip>
openclaw onboard
```

---

## Architecture

```
Internet
    │
    ▼
AWS Security Group
    ├── Port 22  (SSH)   — operator IP only
    ├── Port 80  (HTTP)  — 0.0.0.0/0 (ACME challenge redirect)
    └── Port 443 (HTTPS) — 0.0.0.0/0
         │
         ▼
    EC2 t3.small — Ubuntu 24.04 LTS
    ├── Caddy          (reverse proxy + automatic TLS)
    ├── OpenClaw       (loopback-only, port 18789)
    ├── fail2ban       (SSH brute-force protection)
    └── UFW            (host firewall)
```

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `project_name` | Prefix for all AWS resource names | `openclaw` |
| `name_suffix` | Unique suffix for S3 bucket names (e.g. `gs08`) | _(required)_ |
| `region` | AWS region | `us-east-2` |
| `instance_type` | EC2 instance type | `t3.small` |
| `my_ip` | Your IP in CIDR — SSH allowlist | _(required)_ |
| `key_name` | Name of existing EC2 key pair | _(required)_ |
| `domain` | Domain/subdomain for OpenClaw | _(required)_ |
| `hosted_zone_name` | Route 53 hosted zone name | _(required)_ |
| `budget_alert_email` | Email for monthly cost alerts | _(required)_ |
| `budget_limit_usd` | Monthly budget threshold in USD | `25` |

## Prerequisites

- AWS account with permissions for EC2, VPC, EIP, S3, DynamoDB, Route 53, and Budgets
- An existing EC2 key pair for SSH access
- A Route 53 hosted zone for your domain
- Terraform ≥ 1.6 (for the local bootstrap step only)

## Security

- SSH: key-only, root login disabled, max 3 auth tries
- EC2 Security Group: SSH restricted to operator IP
- fail2ban: SSH jail (5 retries, 1-hour ban)
- UFW: default deny, only 22/80/443 open
- IMDSv2 enforced
- EBS encrypted at rest, Terraform state encrypted in S3

## Teardown

```bash
cd terraform/
terraform destroy -var-file=terraform.tfvars
```

The bootstrap S3 bucket and DynamoDB table have `prevent_destroy = true`. To remove them, run `terraform destroy` inside `terraform/bootstrap/` separately.
