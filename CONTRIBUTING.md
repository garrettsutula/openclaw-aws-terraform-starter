# Contributing

Thanks for your interest in improving openclaw-aws-terraform-starter!

## Reporting Issues

Open a GitHub issue with:
- What you were trying to do
- What happened vs. what you expected
- Your Terraform version (`terraform version`) and AWS region

## Submitting Changes

1. Fork the repo and create a branch from `main`
2. Make your changes — keep PRs focused on a single concern
3. Test your changes (`terraform validate`, `terraform plan`)
4. Open a pull request with a clear description of what changed and why

## What's in scope

- Bug fixes and security improvements to the Terraform config or cloud-init script
- Documentation improvements
- Support for additional AWS regions or configurations
- CI/CD workflow improvements

## What's out of scope

- Support for cloud providers other than AWS (open a separate project)
- Application-level OpenClaw configuration (see the [OpenClaw docs](https://docs.openclaw.ai))

## Code style

- Follow existing Terraform conventions (2-space indent, descriptive variable names)
- Keep `user_data.sh` readable — add comments for non-obvious steps
- Update `README.md` and `example.tfvars` when adding new variables
