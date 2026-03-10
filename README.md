# openclaw-aws-terraform-starter

Terraform + GitHub Actions for deploying [OpenClaw](https://github.com/openclaw/openclaw) on AWS EC2 with security hardening.

## Getting Started (First Time)

1. **Fork this repo** and clone it locally.

2. **Bootstrap remote state** — creates the S3 bucket and DynamoDB table Terraform uses to store state:
   ```bash
   cd terraform/bootstrap/
   terraform init
   terraform apply -var="name_suffix=YOUR_SUFFIX"
   # e.g. your initials + 2 digits: gs08, jd42, etc.
   ```

3. **Update the backend config** — open `terraform/main.tf` and replace `YOURSUFFIX` in the `backend "s3"` block with your suffix:
   ```hcl
   backend "s3" {
     bucket = "openclaw-terraform-state-YOUR_SUFFIX"
     ...
   }
   ```

4. **Copy and fill in your variables:**
   ```bash
   cd terraform/
   cp example.tfvars terraform.tfvars
   $EDITOR terraform.tfvars   # fill in all required fields
   ```

5. **Add GitHub Actions secrets** (Settings → Secrets and variables → Actions) — see table below.

6. **Deploy:**
   ```bash
   terraform init
   terraform plan -var-file=terraform.tfvars
   terraform apply -var-file=terraform.tfvars
   ```

7. **Onboard OpenClaw** once the instance is up:
   ```bash
   ssh -i ~/.ssh/<your-key>.pem openclaw@<elastic-ip>
   openclaw onboard
   ```



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
    ├── OpenClaw       (native install via Homebrew, loopback-only port 18789)
    ├── fail2ban       (SSH brute-force protection)
    └── UFW            (host firewall, defense-in-depth)
```

**Estimated cost:** ~$20/month (t3.small + 20GB gp3 + Elastic IP + S3 backup ~$0.01/month)

## Prerequisites

- AWS account with IAM credentials that can manage EC2, VPC, EIP, S3, DynamoDB, and Route 53
- An existing EC2 key pair for SSH access
- A Route 53 hosted zone for your domain (Terraform manages the A record automatically)
- Terraform ≥ 1.6 installed locally (for manual deploys)

## Bootstrap: Remote State

Before the first deploy, provision the S3 bucket and DynamoDB table used for Terraform remote state:

```bash
cd terraform/bootstrap/
terraform init
terraform apply -var="name_suffix=YOUR_SUFFIX"  # e.g. your initials + 2 digits
```

This creates:
- S3 bucket (`openclaw-terraform-state-YOUR_SUFFIX`) — versioned, encrypted, private
- DynamoDB table (`terraform-locks`) — for state locking

> ⚠️ After bootstrap, update the `bucket` value in the `backend "s3"` block in `terraform/main.tf` to match your bucket name (`openclaw-terraform-state-YOUR_SUFFIX`), then run `terraform init`.

## Quick Start (local)

```bash
cd terraform/

# 1. Copy and fill in your variables
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars

# 2. Init (pulls remote state from S3) and plan
terraform init
terraform plan -var-file=terraform.tfvars

# 3. Apply
terraform apply -var-file=terraform.tfvars

# 4. DNS is managed automatically via Route 53 — no manual A record needed.
#    Wait ~2 min for cloud-init to finish, then SSH in:
ssh -i ~/.ssh/<your-key>.pem openclaw@<elastic-ip>
```

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `project_name` | Prefix for all AWS resource names | `openclaw` |
| `name_suffix` | Short unique suffix for S3 bucket names (e.g. `gs08`) | _(required)_ |
| `region` | AWS region | `us-east-2` |
| `instance_type` | EC2 instance type | `t3.small` |
| `my_ip` | Your IP in CIDR (e.g. `1.2.3.4/32`) — SSH allowlist | _(required)_ |
| `key_name` | Name of existing EC2 key pair | _(required)_ |
| `domain` | Domain/subdomain for OpenClaw (e.g. `openclaw.example.com`) | _(required)_ |
| `hosted_zone_name` | Route 53 hosted zone name (e.g. `example.com`) | _(required)_ |
| `budget_alert_email` | Email to notify when monthly cost exceeds threshold | _(required)_ |
| `budget_limit_usd` | Monthly budget threshold in USD | `25` |

## GitHub Actions (CI/CD)

Two workflows are included:

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `terraform-plan.yml` | PR to `main` | Runs `terraform plan`, posts output as PR comment |
| `terraform-apply.yml` | Merge to `main` | Runs `terraform apply` in the `production` environment |

### Required Secrets

Configure these in **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_REGION` | e.g. `us-east-2` |
| `OPERATOR_IP` | Your public IP in CIDR, e.g. `1.2.3.4/32` |
| `EC2_KEY_NAME` | Name of EC2 key pair |
| `OPENCLAW_DOMAIN` | e.g. `openclaw.example.com` |
| `HOSTED_ZONE_NAME` | Route 53 hosted zone, e.g. `example.com` |
| `BUDGET_ALERT_EMAIL` | Email address for cost alert notifications |
| `NAME_SUFFIX` | Your unique suffix (must match bootstrap) |

### Production Environment

The apply workflow runs in the **`production`** GitHub environment. Configure it in **Settings → Environments → production** to require manual approval before any apply runs.

## Security Hardening (applied by cloud-init)

- SSH: password auth disabled, root login disabled, key-only, max 3 auth tries
- UFW: default deny inbound; only 22/80/443 open
- fail2ban: SSH jail, 5 retries, 1-hour ban
- EC2 Security Group: SSH allowlisted to operator IP only
- IMDSv2 enforced (no unauthenticated metadata access)
- EBS volume encrypted at rest
- Terraform state encrypted at rest in S3

## Post-Deploy Checklist

```bash
# Verify SSH key-only auth
ssh openclaw@<ip>

# Confirm password auth is rejected
ssh -o PubkeyAuthentication=no openclaw@<ip>   # should fail

# Check services
sudo fail2ban-client status sshd
sudo ufw status numbered
ss -tlnp | grep 18789   # should show 127.0.0.1 only

# OpenClaw onboarding
openclaw onboard
```

## Teardown

```bash
cd terraform/
terraform destroy -var-file=terraform.tfvars
```

> Note: The bootstrap S3 bucket and DynamoDB table are not destroyed by the above command (they have `prevent_destroy = true`). To remove them, run `terraform destroy` inside `terraform/bootstrap/` separately.
