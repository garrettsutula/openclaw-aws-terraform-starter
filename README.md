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
| `OPENCLAW_SSH_PUBLIC_KEY` | Contents of your public key file, e.g. `~/.ssh/openclaw-ssh.pub` |

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
    └── Port 443 (HTTPS) — operator IP only
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
| `openclaw_ssh_public_key` | Public key contents for the `openclaw-ssh` key pair | _(required)_ |

## Security

- SSH: key-only, root login disabled, max 3 auth tries
- EC2 Security Group: SSH restricted to operator IP
- fail2ban: SSH jail (5 retries, 1-hour ban)
- UFW: default deny, only 22/80/443 open
- IMDSv2 enforced
- EBS encrypted at rest, Terraform state encrypted in S3

## Updating OpenClaw

To update OpenClaw to the latest version, SSH onto the instance and run:

```bash
ssh -i ~/.ssh/<your-key>.pem openclaw@<elastic-ip>
openclaw update
```

If a new version of the terraform config is needed (e.g. new instance type or security group rules), push changes to `main` and the apply workflow will update the infrastructure.

## Restoring from Backup

If you need to restore OpenClaw config from an S3 backup:

```bash
# List available backups
aws s3 ls s3://<project-name>-backups-<name_suffix>/backups/

# Download and extract a specific backup
aws s3 cp s3://<project-name>-backups-<name_suffix>/backups/<backup-timestamp>.tar.gz /tmp/openclaw-backup.tar.gz
tar -xzf /tmp/openclaw-backup.tar.gz -C /home/openclaw/

# Restart OpenClaw to pick up restored config
sudo systemctl restart openclaw
```

## Backup System

OpenClaw automatically backs up its config to S3 daily at 03:00 UTC via a systemd timer (`openclaw-backup.timer`). The timer runs as the `openclaw` user and uploads a `.tar.gz` archive (excluding secrets, logs, media, and workspace) to `s3://<project-name>-backups-<name_suffix>/backups/`. Backups expire after 30 days (S3 lifecycle rule).

Monitor backup health via the CloudWatch alarm `openclaw-backup-missing`. It fires if the S3 bucket shows zero backup objects, which indicates the backup script or timer failed.

## Troubleshooting

### SSH access denied

- Verify your public IP hasn't changed (check [ifconfig.me](https://ifconfig.me))
- Confirm the `OPERATOR_IP` secret in GitHub Actions matches your current IP in CIDR notation (e.g. `1.2.3.4/32`)
- Ensure the security group allows port 22 from your IP

### OpenClaw not reachable after instance start

- Check that the Route 53 A record points to the correct Elastic IP
- Verify Caddy is running: `sudo systemctl status caddy`
- Verify OpenClaw is running: `sudo systemctl status openclaw`
- Check Caddy logs: `tail -f /var/log/caddy/access.log`
- Check OpenClaw logs: `journalctl -u openclaw`

### CloudWatch alarms not firing

- Ensure the CloudWatch Agent is running: `sudo systemctl status amazon-cloudwatch-agent`
- Verify the agent config: `cat /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json`
- Test metric submission manually: `aws cloudwatch put-metric-data --namespace CWAgent --metric-name mem_used_percent --value 50 --dimensions InstanceId=<instance-id>`

### Backup script fails

- Verify the IAM instance profile has S3 permissions (checked in the `openclaw-s3-backups` policy)
- Run the backup script manually to see error output: `/home/openclaw/bin/openclaw-backup.sh`
- Ensure the S3 bucket exists and the instance can reach it: `aws s3 ls s3://<project-name>-backups-<name_suffix>/`
- Check the systemd timer: `sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) systemctl --user list-timers`

### Terraform plan/apply fails in CI

- Verify `NAME_SUFFIX` matches the suffix used during bootstrap
- Confirm AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are still valid
- Check that the S3 bucket and DynamoDB table still exist (they have `prevent_destroy` so they survive `terraform destroy`)

## Teardown

```bash
cd terraform/
terraform destroy -var-file=terraform.tfvars
```

The bootstrap S3 bucket and DynamoDB table have `prevent_destroy = true`. To remove them, run `terraform destroy` inside `terraform/bootstrap/` separately.
