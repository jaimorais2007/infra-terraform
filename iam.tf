# Um usuário IAM por serviço, com permissão mínima: publicar nos próprios tópicos,
# consumir a própria fila e (no Billing) acessar a tabela DynamoDB.
# Os serviços rodam no k3s fora da AWS, por isso usam access key.
# As access keys NÃO são criadas aqui (ficariam no state): crie pelo console
# e grave como Secret no Kubernetes (veja o README).

resource "aws_iam_user" "service" {
  for_each = toset(var.services)
  name     = "${var.project}-${each.key}-service"
}

data "aws_iam_policy_document" "service" {
  for_each = toset(var.services)

  dynamic "statement" {
    for_each = length(local.published_topics[each.key]) > 0 ? [1] : []
    content {
      sid       = "PublishOwnEvents"
      actions   = ["sns:Publish"]
      resources = [for event in local.published_topics[each.key] : aws_sns_topic.event[event].arn]
    }
  }

  statement {
    sid = "ConsumeOwnQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.events[each.key].arn]
  }

  # Envio direto (sem SNS) para filas de outros serviços, ex.: o OS manda as
  # notificações de mudança de status para a fila do execution, que envia o e-mail.
  dynamic "statement" {
    for_each = length(lookup(var.direct_queue_targets, each.key, [])) > 0 ? [1] : []
    content {
      sid       = "SendToOtherQueues"
      actions   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
      resources = [for target in var.direct_queue_targets[each.key] : aws_sqs_queue.events[target].arn]
    }
  }

  dynamic "statement" {
    for_each = each.key == "billing" ? [1] : []
    content {
      sid = "BillingTable"
      actions = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:ConditionCheckItem",
        "dynamodb:DescribeTable",
      ]
      resources = [
        aws_dynamodb_table.billing.arn,
        "${aws_dynamodb_table.billing.arn}/index/*",
      ]
    }
  }
}

resource "aws_iam_user_policy" "service" {
  for_each = toset(var.services)
  name     = "${var.project}-${each.key}-service"
  user     = aws_iam_user.service[each.key].name
  policy   = data.aws_iam_policy_document.service[each.key].json
}
