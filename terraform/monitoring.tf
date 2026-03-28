# ---------------------------------------------------------------------------
# CloudWatch Monitoring & SNS Alerts
# ---------------------------------------------------------------------------

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = {
    Name    = "${var.project_name}-alerts"
    Project = "openclaw"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

# Disk alarm (CWAgent namespace, fires at >= 70%)
resource "aws_cloudwatch_metric_alarm" "disk_used" {
  alarm_name          = "${var.project_name}-disk-used-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Disk usage >= 70% on root volume"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.openclaw.id
    path       = "/"
    fstype     = "ext4"
    device     = "nvme0n1p1"
  }
  tags = {
    Project = "openclaw"
  }
}

# CPU sustained alarm (>80% for 3 consecutive 5-min periods = 15 minutes sustained)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU >= 80% sustained for 15 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.openclaw.id
  }
  tags = {
    Project = "openclaw"
  }
}

# Network In anomaly alarm
# Uses 3σ band (vs 2σ) and 10-min periods over 4 evaluation windows (40 min sustained)
# to avoid false positives from normal chat interaction bursts while still catching
# sustained anomalies like data exfil, crypto mining, or botnet traffic.
resource "aws_cloudwatch_metric_alarm" "network_in_anomaly" {
  alarm_name          = "${var.project_name}-network-in-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 4
  threshold_metric_id = "e1"
  alarm_description   = "NetworkIn anomaly (>3σ above band sustained for 40 minutes)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  tags = {
    Project = "openclaw"
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "NetworkIn (expected)"
    return_data = true
  }
  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "NetworkIn"
      namespace   = "AWS/EC2"
      period      = 600
      stat        = "Average"
      dimensions  = {
        InstanceId = aws_instance.openclaw.id
      }
    }
  }
}

# Network Out anomaly alarm
# Uses 3σ band (vs 2σ) and 10-min periods over 3 evaluation windows (30 min sustained)
# to avoid false positives from normal chat interaction bursts while still catching
# sustained anomalies like data exfil, crypto mining, or botnet traffic.
resource "aws_cloudwatch_metric_alarm" "network_out_anomaly" {
  alarm_name          = "${var.project_name}-network-out-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "e1"
  alarm_description   = "NetworkOut anomaly (>3σ above band sustained for 30 minutes)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  tags = {
    Project = "openclaw"
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "NetworkOut (expected)"
    return_data = true
  }
  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "NetworkOut"
      namespace   = "AWS/EC2"
      period      = 600
      stat        = "Average"
      dimensions  = {
        InstanceId = aws_instance.openclaw.id
      }
    }
  }
}
