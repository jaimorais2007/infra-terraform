# k8s/ — base do cluster (namespace, bancos, ingress)

Aplicar nesta ordem, depois do k3s estar no ar com o Elastic IP no `tls-san`:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/postgres-os.yaml
kubectl apply -f k8s/postgres-execution.yaml
kubectl apply -f k8s/ingress.yaml
```

## Secrets (nunca commitar os valores reais)

`postgres-os.yaml` e `postgres-execution.yaml` esperam um Secret com a senha do banco, criado
manualmente antes do `kubectl apply`:

```bash
kubectl create secret generic postgres-os-secret \
  -n oficina --from-literal=POSTGRES_PASSWORD='<senha-forte>'

kubectl create secret generic postgres-execution-secret \
  -n oficina --from-literal=POSTGRES_PASSWORD='<senha-forte>'
```

Cada microsserviço (`os-service`, `billing-service`, `execution-service`) também precisa do
próprio Secret com as credenciais que o pipeline de deploy (`ci-templates`) usa — não documentado
aqui porque varia por serviço (connection string, access key AWS, token Mercado Pago no Billing).
Ver o relatório de passagem da Fase 4 para a lista completa por serviço.

## Roteamento (`ingress.yaml`)

Um único `IngressRoute` do Traefik (CRDs `traefik.io/v1alpha1`, já instalado no k3s — confirmado
Traefik 3.7.8) separa por prefixo e remove o prefixo antes de entregar pro serviço:

| Entrada                      | Service (porta 8080) |
| ----------------------------- | --------------------- |
| `http://<EIP>/os/...`        | `os-service`          |
| `http://<EIP>/billing/...`   | `billing-service`     |
| `http://<EIP>/execution/...` | `execution-service`   |

Os `Service` de cada microsserviço são criados pelo próprio pipeline de deploy do serviço
(`ci-templates/dotnet-service.yml`), não por este repositório — este `ingress.yaml` só assume que
eles existem no namespace `oficina` com esses nomes exatos.
