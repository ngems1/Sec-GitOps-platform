output "settings" {
  description = "Everything the Helm values for this environment need."
  value = {
    namespace              = var.namespace
    db_host                = aws_db_instance.mysql.address
    db_port                = aws_db_instance.mysql.port
    db_name                = aws_db_instance.mysql.db_name
    db_secret_arn          = aws_db_instance.mysql.master_user_secret[0].secret_arn
    redis_endpoint         = "${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
    event_bus_name         = aws_cloudwatch_event_bus.retail.name
    inventory_table        = aws_dynamodb_table.inventory.name
    notifications_table    = aws_dynamodb_table.notifications.name
    inventory_queue_url    = aws_sqs_queue.queue["inventory"].id
    notification_queue_url = aws_sqs_queue.queue["notification"].id
    order_status_queue_url = aws_sqs_queue.queue["order-status"].id
    dlq_urls               = { for k, q in aws_sqs_queue.dlq : k => q.id }
    order_status_lambda    = aws_lambda_function.order_status.function_name
    pod_roles              = { for k, r in aws_iam_role.pod : k => r.arn }
    alerts_topic_arn       = aws_sns_topic.alerts.arn
  }
}

output "redis_auth_token" {
  description = "Redis auth token for this environment (the deploy workflow turns it into a Kubernetes Secret)."
  value       = random_password.redis_auth.result
  sensitive   = true
}
