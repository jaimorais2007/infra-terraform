# Banco NoSQL do Billing Service (requisito: pelo menos 1 banco NoSQL).
# Modelo de tabela única com chave composta (pk/sk), para orçamentos, pagamentos
# e o controle de idempotência dos eventos já processados.
# Exemplos de chave (o Roger define o modelo final):
#   pk = "BUDGET#<osId>"  sk = "METADATA"
#   pk = "BUDGET#<osId>"  sk = "PAYMENT#<paymentId>"
#   pk = "EVENT#<eventId>" sk = "PROCESSED"   (com ttl para expirar)

resource "aws_dynamodb_table" "billing" {
  name         = "${var.project}-billing"
  # Capacidade provisionada pequena: tabela + índice somam 10 RCU / 10 WCU,
  # dentro das 25 RCU / 25 WCU da cota sempre gratuita do DynamoDB.
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5

  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Busca de pagamento pelo id da transação no Mercado Pago (usado no webhook).
  attribute {
    name = "gatewayTransactionId"
    type = "S"
  }

  global_secondary_index {
    name            = "by-gateway-transaction"
    hash_key        = "gatewayTransactionId"
    projection_type = "ALL"
    read_capacity   = 5
    write_capacity  = 5
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}
