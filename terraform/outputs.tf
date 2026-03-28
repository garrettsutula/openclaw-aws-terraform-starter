output "public_ip" {
  description = "Elastic IP address"
  value       = aws_eip.openclaw.public_ip
}

output "dns_record" {
  description = "Fully-qualified domain name managed by Route 53"
  value       = aws_route53_record.openclaw.fqdn
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openclaw.id
}

output "ssh_command" {
  description = "Ready-to-paste SSH command"
  value       = "ssh -i ~/.ssh/<your-key>.pem openclaw@${aws_eip.openclaw.public_ip}"
}

output "domain" {
  description = "Domain configured for this deployment"
  value       = var.domain
}

output "alerts_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alerts"
  value       = aws_sns_topic.alerts.arn
}
