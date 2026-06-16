# ── DLQ depth alarm (G-03) ────────────────────────────────────────────────────
# Fires when any message lands in the transform DLQ — signals a failed ingest
resource "aws_cloudwatch_metric_alarm" "transform_dlq_depth" {
  alarm_name          = "${local.name_prefix}-transform-dlq-depth"
  alarm_description   = "Messages in transform DLQ - ingest pipeline failed (G-03)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.transform_dlq.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
