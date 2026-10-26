# infra-terraform

Infraestrutura AWS do Tech Challenge Fase 4 (oficina mecânica em microsserviços).

## O que este repositório cria

| Recurso | Para quê |
| --- | --- |
| 11 tópicos SNS (um por evento da Saga) | Publicação dos eventos; o SNS entrega para todos os consumidores |
| 3 filas SQS + 3 DLQs (uma por serviço) | Cada serviço consome os eventos que lhe interessam; falhas repetidas vão para a DLQ |
| Tabela DynamoDB `oficina-billing` | Banco NoSQL do Billing Service (orçamentos, pagamentos, idempotência) |
| 3 usuários IAM (um por serviço) | Permissão mínima: publicar os próprios eventos, ler a própria fila e, no Billing, acessar o DynamoDB |
| API Gateway HTTP `oficina-fase4-api` | Porta de entrada única; JWT validado pelo authorizer Lambda da Fase 3 |

O state fica no bucket `techchallenge-terraform-state-s3`, key `fase4/infra/terraform.tfstate`, separado do state da Fase 3.

## Contrato de eventos (Saga coreografada)

| Evento | Publicado por | Consumido por |
| --- | --- | --- |
| OrderCreated | os | billing |
| BudgetCreated | billing | os |
| BudgetApproved | billing | os |
| BudgetRejected | billing | os |
| PaymentConfirmed | billing | os, execution |
| PaymentFailed | billing | os |
| PaymentExpired | billing | os |
| PaymentRefunded | billing | os |
| ExecutionStarted | execution | os |
| ExecutionCompleted | execution | os |
| ExecutionFailed | execution | billing, os |

Para mudar o contrato, edite `var.events` em `variables.tf` e abra um PR.

As mensagens chegam na fila sem o envelope do SNS (raw delivery). O tipo do evento vai no campo `eventType` do JSON, e o `traceparent` do OpenTelemetry vai como *message attribute* no publish, que o SNS repassa para o SQS.

## API Gateway

- `POST /authenticate`: Lambda da Fase 3, devolve o JWT (rota pública).
- Rotas dos serviços: exigem `Authorization: Bearer <jwt>`. Prefixos em `var.service_routes`.
- Rotas públicas: webhook do Mercado Pago e health checks (`var.public_routes`).

As rotas de um serviço só são criadas quando a URL dele é preenchida em `var.service_urls`, ou seja, depois que o cluster estiver no ar. Exemplo em `terraform.tfvars`:

```hcl
service_urls = {
  os        = "http://IP_DO_CLUSTER"
  billing   = "http://IP_DO_CLUSTER"
  execution = "http://IP_DO_CLUSTER"
}
```

## Como executar

Pelo pipeline (recomendado): abra um PR. O GitHub Actions roda `fmt`, `validate` e `plan`, e o plano aparece no resumo da execução. No merge na `main`, roda o `apply`.

Secrets necessários no repositório: `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`.

Localmente:

```bash
terraform init
terraform plan
terraform apply
```

## Depois do primeiro apply

1. No console IAM, crie uma access key para cada usuário `oficina-<servico>-service`.
2. Grave no Kubernetes como Secret do serviço (`AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`).
3. Passe para cada dev os valores de `terraform output`: ARNs dos tópicos, URL da fila e nome da tabela.

## Custo

- SNS, SQS e DynamoDB (5 RCU/WCU na tabela e no índice) ficam dentro da cota sempre gratuita no volume do projeto.
- O API Gateway HTTP não tem cota sempre gratuita: custa cerca de US$ 1 por milhão de chamadas, ou seja, centavos no volume de testes e da demonstração.
- Não há EKS, RDS nem NAT Gateway.
