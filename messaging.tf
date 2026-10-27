# Mensageria da Saga coreografada: SNS (um tópico por evento) -> SQS (uma fila por serviço consumidor).
# SNS faz o fan-out para vários consumidores; SQS garante entrega e reprocessamento; DLQ isola falhas.

locals {
  # Todas as combinações evento -> consumidor, para criar as subscriptions.
  subscriptions = {
    for pair in flatten([
      for event, cfg in var.events : [
        for consumer in cfg.consumers : {
          key      = "${event}-${consumer}"
          event    = event
          consumer = consumer
        }
      ]
    ]) : pair.key => pair
  }

  # Para cada serviço, os tópicos que ele consome (usado na policy da fila).
  consumed_topics = {
    for svc in var.services : svc => [
      for event, cfg in var.events : event if contains(cfg.consumers, svc)
    ]
  }

  # Para cada serviço, os tópicos que ele publica (usado na policy IAM do serviço).
  published_topics = {
    for svc in var.services : svc => [
      for event, cfg in var.events : event if cfg.publisher == svc
    ]
  }
}

resource "aws_sns_topic" "event" {
  for_each = var.events
  name     = "${var.project}-${each.key}"
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = toset(var.services)
  name                      = "${var.project}-${each.key}-events-dlq"
  message_retention_seconds = 1209600 # 14 dias para investigar falhas
}

resource "aws_sqs_queue" "events" {
  for_each                   = toset(var.services)
  name                       = "${var.project}-${each.key}-events"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 dias
  receive_wait_time_seconds  = 20     # long polling: menos chamadas, dentro da cota gratuita

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.dlq_max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each  = toset(var.services)
  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events[each.key].arn]
  })
}

# Só os tópicos que o serviço consome podem entregar mensagens na fila dele.
data "aws_iam_policy_document" "queue_from_sns" {
  for_each = { for svc, topics in local.consumed_topics : svc => topics if length(topics) > 0 }

  statement {
    sid       = "AllowSnsDelivery"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for event in each.value : aws_sns_topic.event[event].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "events" {
  for_each  = data.aws_iam_policy_document.queue_from_sns
  queue_url = aws_sqs_queue.events[each.key].id
  policy    = each.value.json
}

resource "aws_sns_topic_subscription" "event_to_queue" {
  for_each = local.subscriptions

  topic_arn = aws_sns_topic.event[each.value.event].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.events[each.value.consumer].arn

  # Entrega o JSON do evento como foi publicado, sem o envelope do SNS.
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.events]
}
