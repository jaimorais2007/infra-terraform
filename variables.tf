variable "aws_region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
  default     = "oficina"
}

variable "services" {
  description = "Microsserviços que publicam e consomem eventos"
  type        = list(string)
  default     = ["os", "billing", "execution"]
}

# Contrato de eventos da Saga coreografada (doc de alinhamento do grupo).
# Cada evento vira um tópico SNS; cada consumidor recebe o evento na sua fila SQS.
variable "events" {
  description = "Mapa evento => { publisher, consumers }"
  type = map(object({
    publisher = string
    consumers = list(string)
  }))
  default = {
    OrderCreated       = { publisher = "os", consumers = ["billing"] }
    BudgetCreated      = { publisher = "billing", consumers = ["os"] }
    BudgetApproved     = { publisher = "billing", consumers = ["os"] }
    BudgetRejected     = { publisher = "billing", consumers = ["os"] }
    PaymentConfirmed   = { publisher = "billing", consumers = ["os", "execution"] }
    PaymentFailed      = { publisher = "billing", consumers = ["os"] }
    PaymentExpired     = { publisher = "billing", consumers = ["os"] }
    PaymentRefunded    = { publisher = "billing", consumers = ["os"] }
    ExecutionStarted   = { publisher = "execution", consumers = ["os"] }
    ExecutionCompleted = { publisher = "execution", consumers = ["os"] }
    ExecutionFailed    = { publisher = "execution", consumers = ["billing", "os"] }
  }
}

variable "dlq_max_receive_count" {
  description = "Tentativas de processamento antes de a mensagem ir para a DLQ"
  type        = number
  default     = 5
}

# URL base de cada serviço no cluster (ingress do k3s).
# Enquanto estiver vazia, as rotas daquele serviço não são criadas no API Gateway.
variable "service_urls" {
  description = "URL base pública de cada serviço, ex.: http://203.0.113.10"
  type        = map(string)
  default = {
    os        = ""
    billing   = ""
    execution = ""
  }
}

# Prefixos de rota de cada serviço. Ajustar conforme os controllers que os devs criarem.
variable "service_routes" {
  description = "Mapa serviço => lista de prefixos de path atendidos por ele"
  type        = map(list(string))
  default = {
    os        = ["/api/ServiceOrders", "/api/Customer", "/api/Vehicle"]
    billing   = ["/api/Budgets", "/api/Payments"]
    execution = ["/api/Executions", "/api/Parts", "/api/Service"]
  }
}

# Rotas sem autenticação (webhook do Mercado Pago e health checks).
# Chave = rota no API Gateway; path = caminho chamado no serviço.
variable "public_routes" {
  description = "Mapa 'METHOD /rota' => { service, path }"
  type = map(object({
    service = string
    path    = string
  }))
  default = {
    "POST /api/webhooks/mercadopago" = { service = "billing", path = "/api/webhooks/mercadopago" }
    "GET /os/health"                 = { service = "os", path = "/health" }
    "GET /billing/health"            = { service = "billing", path = "/health" }
    "GET /execution/health"          = { service = "execution", path = "/health" }
  }
}

variable "authorizer_lambda_name" {
  description = "Lambda authorizer da Fase 3 (valida o JWT)"
  type        = string
  default     = "oficina-mecanica-authorizer"
}

variable "authenticate_lambda_name" {
  description = "Lambda de autenticação por CPF da Fase 3 (emite o JWT)"
  type        = string
  default     = "oficina-mecanica-authenticate"
}
