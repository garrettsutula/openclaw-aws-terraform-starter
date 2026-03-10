# Copy to terraform.tfvars (gitignored) and fill in your values.
# Or pass via -var flags as shown in the README.

region        = "us-east-1"
instance_type = "t3.small"
my_ip         = "1.2.3.4/32"   # your public IP — curl ifconfig.me
key_name      = "my-ec2-key"   # name of existing EC2 key pair
domain        = "openclaw.example.com"
project_name       = "openclaw"
name_suffix        = "abc123"  # replace with a short unique string (e.g. your initials + 2 digits)
budget_alert_email = "your-email@example.com"
budget_limit_usd   = 25
