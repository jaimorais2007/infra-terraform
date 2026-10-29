output "k3s_cluster_eip" {
  description = "Elastic IP fixo da EC2 do cluster k3s"
  value       = data.aws_eip.k3s_cluster.public_ip
}

output "api_endpoint" {
  description = "URL do API Gateway da Fase 4"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "sns_topic_arns" {
  description = "ARN do tópico SNS de cada evento (usado pelo publicador)"
  value       = { for event, topic in aws_sns_topic.event : event => topic.arn }
}

output "sqs_queue_urls" {
  description = "URL da fila de eventos de cada serviço (usada pelo consumidor)"
  value       = { for svc, queue in aws_sqs_queue.events : svc => queue.url }
}

output "sqs_dlq_urls" {
  description = "URL da DLQ de cada serviço"
  value       = { for svc, queue in aws_sqs_queue.dlq : svc => queue.url }
}

output "dynamodb_billing_table" {
  description = "Nome da tabela DynamoDB do Billing"
  value       = aws_dynamodb_table.billing.name
}

output "service_iam_users" {
  description = "Usuário IAM de cada serviço (crie a access key pelo console)"
  value       = { for svc, user in aws_iam_user.service : svc => user.name }
}

output "routes_created" {
  description = "Rotas criadas no API Gateway"
  value = concat(
    ["POST /authenticate"],
    keys(local.proxy_routes),
    keys(local.public_routes),
  )
}
