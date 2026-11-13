#!/usr/bin/env bash
# =============================================================================
#  Demo da Fase 4 - Oficina Mecânica em microsserviços + Saga coreografada
#
#  Roda tudo pelo API Gateway (mesma porta de entrada do cliente final),
#  autenticando com JWT da Lambda da Fase 3.
#
#  Requisitos: bash + curl (Linux, macOS, WSL ou Git Bash no Windows).
#
#  Uso:
#     export AUTH_CPF="<cpf de login>"        # CPF cadastrado para login
#     ./demo-saga.sh                           # menu interativo
#     ./demo-saga.sh 1                         # roda direto um cenário
#
#  Cenários:
#     1) Caminho feliz: OS -> orçamento -> pagamento MP -> estoque -> entrega
#     2) Falha / compensação 1: cliente rejeita -> pagamento cancelado
#     3) Falha / compensação 2: pago, mas sem estoque -> estorno automático
#     4) Rodar 1, 2 e 3 em sequência
#
#  Variáveis opcionais:
#     GATEWAY=https://...        URL do API Gateway (padrão abaixo)
#     DEMO_EMAIL=voce@x.com      e-mail do cliente criado (notificações)
#     PAUSE=0                    não pausa entre etapas (padrão: pausa)
# =============================================================================
set -uo pipefail

GATEWAY="${GATEWAY:-https://kwzh4dl581.execute-api.us-east-1.amazonaws.com}"
AUTH_CPF="${AUTH_CPF:-}"
DEMO_EMAIL="${DEMO_EMAIL:-demo.oficina@example.com}"
PAUSE="${PAUSE:-1}"
WAIT_PAYMENT_SECONDS="${WAIT_PAYMENT_SECONDS:-600}"

# ---------- visual ----------
if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; M=$'\e[35m'; N=$'\e[0m'
else
  B=""; DIM=""; R=""; G=""; Y=""; C=""; M=""; N=""
fi

titulo() { echo; echo "${B}${M}════════════════════════════════════════════════════════════════${N}"; echo "${B}${M}  $*${N}"; echo "${B}${M}════════════════════════════════════════════════════════════════${N}"; }
etapa()  { echo; echo "${B}${C}▶ $*${N}"; }
info()   { echo "  ${DIM}$*${N}"; }
ok()     { echo "  ${G}✔ $*${N}"; }
aviso()  { echo "  ${Y}⚠ $*${N}"; }
erro()   { echo "  ${R}✘ $*${N}"; }
evento() { echo "  ${Y}⚡ evento:${N} ${B}$*${N}"; }
pausa()  { [ "$PAUSE" = "1" ] && read -r -p "  ${DIM}[Enter para continuar]${N} " _ || true; }

status_nome() {
  case "$1" in
    1) echo "Received (Recebida)";; 2) echo "UnderAnalysis (Em diagnóstico)";;
    3) echo "AwaitingApproval (Aguardando aprovação)";; 4) echo "InProgress (Em execução)";;
    5) echo "Completed (Finalizada)";; 6) echo "Delivered (Entregue)";;
    7) echo "Rejected (Rejeitada)";; 8) echo "WaitingPayment (Aguardando pagamento)";;
    *) echo "$1";;
  esac
}

# ---------- JSON sem dependências (campos simples) ----------
jstr()  { grep -o "\"$1\":\"[^\"]*\"" | head -1 | sed -E "s/\"$1\":\"([^\"]*)\"/\1/"; }
jnum()  { grep -o "\"$1\":[-0-9.]*" | head -1 | sed -E "s/\"$1\"://"; }
jbool() { grep -o "\"$1\":\(true\|false\)" | head -1 | sed -E "s/\"$1\"://"; }

# ---------- autenticação (token da Lambda dura ~1 min: renova sozinho) ----------
# (estado em arquivos porque as funções rodam dentro de $(...) / subshell)
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
token() {
  local agora ts=0 tok=""; agora=$(date +%s)
  [ -f "$TMPD/token" ] && { ts=$(cat "$TMPD/token_ts"); tok=$(cat "$TMPD/token"); }
  if [ -z "$tok" ] || [ $((agora - ts)) -ge 40 ]; then
    local resp
    resp=$(curl -s -m 20 -X POST "$GATEWAY/authenticate" -H 'Content-Type: application/json' -d "{\"cpf\":\"$AUTH_CPF\"}")
    tok=$(echo "$resp" | jstr token)
    if [ -z "$tok" ]; then erro "Falha no login (/authenticate): $resp" >&2; return 1; fi
    echo "$tok" > "$TMPD/token"; echo "$agora" > "$TMPD/token_ts"
  fi
  echo "$tok"
}

# api MÉTODO CAMINHO [JSON]  -> imprime corpo; HTTP code fica em $TMPD/http
api() {
  local metodo="$1" caminho="$2" corpo="${3:-}" out HTTP
  out="$TMPD/body.$$.$RANDOM"
  if [ -n "$corpo" ]; then
    HTTP=$(curl -s -m 30 -o "$out" -w '%{http_code}' -X "$metodo" "$GATEWAY$caminho" \
      -H "Authorization: Bearer $(token)" -H 'Content-Type: application/json' -d "$corpo")
  else
    HTTP=$(curl -s -m 30 -o "$out" -w '%{http_code}' -X "$metodo" "$GATEWAY$caminho" \
      -H "Authorization: Bearer $(token)")
  fi
  echo "$HTTP" > "$TMPD/http"
  cat "$out"; rm -f "$out"
}

checa() { # checa "<descrição>" -> aborta se HTTP não for 2xx
  local HTTP; HTTP=$(cat "$TMPD/http" 2>/dev/null)
  if [[ "$HTTP" =~ ^2 ]]; then ok "$1 ${DIM}(HTTP $HTTP)${N}"; else erro "$1 falhou (HTTP $HTTP)"; exit 1; fi
}

mostra_os() { # mostra_os <id>
  local os; os=$(api GET "/api/ServiceOrders/$1")
  local st; st=$(echo "$os" | jnum status)
  echo "  ${B}OS${N} $1"
  echo "     status....: ${B}$(status_nome "$st")${N}"
  echo "     orçamento.: R\$ $(echo "$os" | jnum budget)   pago: $(echo "$os" | jbool isPaid)"
  local url; url=$(echo "$os" | jstr paymentUrl); [ -n "$url" ] && echo "     link MP...: $url"
  local ens; ens=$(echo "$os" | grep -o '"stockQuantityWasEnsured":\(true\|false\)' | sed 's/.*://' | tr '\n' ' ')
  [ -n "$ens" ] && echo "     estoque garantido por peça: $ens"
}

espera_status() { # espera_status <id> <status> <timeout_s> <msg>
  local id="$1" alvo="$2" limite="$3" msg="$4" ini st
  ini=$(date +%s)
  info "$msg"
  while :; do
    st=$(api GET "/api/ServiceOrders/$id" | jnum status)
    [ "$st" = "$alvo" ] && { echo; ok "OS chegou em $(status_nome "$alvo") após $(( $(date +%s) - ini ))s"; return 0; }
    [ $(( $(date +%s) - ini )) -ge "$limite" ] && { echo; erro "Tempo esgotado (status atual: $(status_nome "$st"))"; return 1; }
    printf '.'; sleep 3
  done
}

espera_campo() { # espera_campo <id> <campo> <timeout_s> <msg>
  local id="$1" campo="$2" limite="$3" msg="$4" ini v
  ini=$(date +%s)
  info "$msg"
  while :; do
    v=$(api GET "/api/ServiceOrders/$id" | jstr "$campo")
    [ -n "$v" ] && { echo; ok "Recebido após $(( $(date +%s) - ini ))s"; return 0; }
    [ $(( $(date +%s) - ini )) -ge "$limite" ] && { echo; erro "Tempo esgotado esperando $campo"; return 1; }
    printf '.'; sleep 2
  done
}

estoque() { api GET "/api/Parts/$1" | jnum quantityInStock; }

# ---------- dados de teste ----------
gera_cpf() {
  local d=() i s r
  for i in 0 1 2 3 4 5 6 7 8; do d[$i]=$((RANDOM % 10)); done
  s=0; for i in 0 1 2 3 4 5 6 7 8; do s=$((s + d[i] * (10 - i))); done
  r=$((s % 11)); d[9]=$(( r < 2 ? 0 : 11 - r ))
  s=0; for i in 0 1 2 3 4 5 6 7 8 9; do s=$((s + d[i] * (11 - i))); done
  r=$((s % 11)); d[10]=$(( r < 2 ? 0 : 11 - r ))
  printf '%s' "${d[@]}"
}
gera_placa() {
  local L=ABCDEFGHIJKLMNOPQRSTUVWXYZ
  printf 'DM%s%d%s%02d' "${L:RANDOM%26:1}" $((RANDOM % 10)) "${L:RANDOM%26:1}" $((RANDOM % 100))
}

CLIENTE_ID=""; VEICULO_ID=""; SERVICO_ID=""
prepara_cadastros() { # cliente + veículo (RegistryService) e serviço (Billing)
  etapa "Cadastro do cliente e do veículo  ${DIM}→ RegistryService (PostgreSQL)${N}"
  local cpf placa r
  cpf=$(gera_cpf); placa=$(gera_placa)
  r=$(api POST /api/Customer "{\"name\":\"Cliente Demo $placa\",\"personType\":1,\"document\":\"$cpf\",\"dateOfBirth\":\"1990-05-10T00:00:00Z\",\"email\":\"$DEMO_EMAIL\"}")
  checa "Cliente criado"; CLIENTE_ID=$(echo "$r" | jstr id); info "cliente $CLIENTE_ID"
  r=$(api POST /api/Vehicle "{\"customerId\":\"$CLIENTE_ID\",\"plate\":\"$placa\",\"brand\":\"Fiat\",\"model\":\"Argo\",\"year\":2022}")
  checa "Veículo $placa criado"; VEICULO_ID=$(echo "$r" | jstr id); info "veículo $VEICULO_ID"

  etapa "Catálogo: serviço  ${DIM}→ BillingService (DynamoDB)${N}"
  r=$(api POST /api/Service '{"name":"Troca de óleo (demo)","description":"Demo Fase 4","defaultPrice":50}')
  checa "Serviço criado (R\$ 50)"; SERVICO_ID=$(echo "$r" | jstr id)
}

cria_peca() { # cria_peca <nome> <estoque> <preço>  -> ID em PECA_ID
  local r
  r=$(api POST /api/Parts "{\"name\":\"$1\",\"code\":\"DEMO-$RANDOM\",\"initialQuantity\":$2,\"price\":$3}")
  checa "Peça '$1' criada com estoque $2 (R\$ $3)"; PECA_ID=$(echo "$r" | jstr id)
}

abre_os_ate_aprovacao() { # abre_os_ate_aprovacao <peça_id> <nome> <qtd> <preço>  -> OS_ID
  etapa "Abertura da OS  ${DIM}→ OSService (PostgreSQL)${N}"
  local r
  r=$(api POST /api/ServiceOrders "{\"customerId\":\"$CLIENTE_ID\",\"vehicleId\":\"$VEICULO_ID\"}")
  checa "OS aberta"; OS_ID=$(echo "$r" | jstr id)
  api POST "/api/ServiceOrders/$OS_ID/start-diagnostics" >/dev/null; checa "Diagnóstico iniciado"
  api POST "/api/ServiceOrders/$OS_ID/parts" "{\"partId\":\"$1\",\"partName\":\"$2\",\"quantity\":$3,\"unitPrice\":$4}" >/dev/null
  checa "Peça adicionada ($3 x R\$ $4)"
  api POST "/api/ServiceOrders/$OS_ID/services" "{\"serviceId\":\"$SERVICO_ID\",\"serviceName\":\"Troca de óleo (demo)\",\"price\":50}" >/dev/null
  checa "Serviço adicionado (R\$ 50)"
  api POST "/api/ServiceOrders/$OS_ID/finish-analysis" '{"budget":0}' >/dev/null; checa "Orçamento gerado"
  mostra_os "$OS_ID"
  pausa

  etapa "Cliente APROVA o orçamento  ${DIM}→ início da Saga${N}"
  api POST "/api/ServiceOrders/$OS_ID/approve" >/dev/null; checa "OS aprovada"
  evento "BudgetApproved  (OSService → SNS → SQS → BillingService)"
  espera_campo "$OS_ID" paymentUrl 90 "Billing cria a cobrança no Mercado Pago e devolve o link..." || exit 1
  evento "PaymentCreated  (BillingService → SNS → SQS → OSService)"
  mostra_os "$OS_ID"
}

instrucoes_pagamento() {
  local url; url=$(api GET "/api/ServiceOrders/$OS_ID" | jstr paymentUrl)
  echo
  echo "  ${B}${Y}>>> PAGUE AGORA no link abaixo (conta de teste, sem dinheiro real):${N}"
  echo "      ${B}$url${N}"
  echo "      Cartão: 5031 4332 1540 6351 · CVV 123 · validade 11/30"
  echo "      Nome do titular: ${B}APRO${N} · CPF 12345678909"
}

# ---------- cenários ----------
cenario_1() {
  titulo "CENÁRIO 1 — Caminho feliz: OS completa passando pelos 3 serviços"
  prepara_cadastros
  cria_peca "Filtro de óleo (demo)" 10 30
  local est_antes; est_antes=$(estoque "$PECA_ID")
  pausa
  abre_os_ate_aprovacao "$PECA_ID" "Filtro de óleo (demo)" 1 30
  instrucoes_pagamento
  espera_status "$OS_ID" 4 "$WAIT_PAYMENT_SECONDS" "Aguardando o webhook do Mercado Pago..." || exit 1
  evento "PaymentConfirmed     (webhook MP → BillingService → OSService)"
  evento "ServiceOrderApproved (OSService → BillingService: reservar peças)"
  evento "PartStockEnsured     (BillingService → OSService: estoque garantido)"
  ok "Estoque da peça: $est_antes → $(estoque "$PECA_ID")"
  mostra_os "$OS_ID"
  pausa

  etapa "Execução e entrega"
  api POST "/api/ServiceOrders/$OS_ID/finish-execution" >/dev/null; checa "Serviço finalizado"
  api POST "/api/ServiceOrders/$OS_ID/deliver" >/dev/null; checa "Veículo entregue"
  mostra_os "$OS_ID"
  echo; ok "${B}Cenário 1 concluído.${N}"
}

cenario_2() {
  titulo "CENÁRIO 2 — Falha/compensação: cliente rejeita após aprovar"
  prepara_cadastros
  cria_peca "Pastilha de freio (demo)" 10 40
  pausa
  abre_os_ate_aprovacao "$PECA_ID" "Pastilha de freio (demo)" 1 40
  pausa
  etapa "Cliente DESISTE (rejeita) antes de pagar"
  local OS_A=$OS_ID
  api POST "/api/ServiceOrders/$OS_ID/reject" >/dev/null; checa "OS rejeitada"
  evento "ServiceOrderRejected (OSService → BillingService)"
  info "Compensação: BillingService cancela a cobrança pendente no Mercado Pago."
  info "O link de pagamento é removido da OS e ela não pode mais ser paga."
  mostra_os "$OS_ID"
  echo; ok "${B}Cenário 2 concluído.${N}"
}

cenario_3() {
  titulo "CENÁRIO 3 — Falha/compensação: pago, mas peça sem estoque → estorno"
  prepara_cadastros
  cria_peca "Amortecedor (demo)" 1 60
  info "A peça tem só 1 unidade; a OS vai pedir 2."
  pausa
  abre_os_ate_aprovacao "$PECA_ID" "Amortecedor (demo)" 2 60
  instrucoes_pagamento
  espera_status "$OS_ID" 3 "$WAIT_PAYMENT_SECONDS" "Aguardando pagamento → falta de estoque → estorno..." || exit 1
  evento "PaymentConfirmed     (webhook MP → BillingService → OSService)"
  evento "ServiceOrderApproved (OSService → BillingService: reservar peças)"
  aviso "BillingService: estoque insuficiente (pedido 2, disponível 1)"
  evento "PaymentRefunded      (BillingService estorna no MP → OSService)"
  info "Compensação: pagamento estornado e a OS volta para Aguardando aprovação."
  ok "Estoque da peça continua em $(estoque "$PECA_ID") (nada foi debitado)"
  mostra_os "$OS_ID"
  echo; ok "${B}Cenário 3 concluído.${N}"
}

# ---------- teste completo automático (placar no final) ----------
RES_NOMES=(); RES_OK=()
registra() { RES_NOMES+=("$1"); RES_OK+=("$2"); [ "$2" = "1" ] && ok "PASSOU: $1" || erro "FALHOU: $1"; }
status_de() { api GET "/api/ServiceOrders/$1" | jnum status; }

teste_completo() {
  PAUSE=0
  titulo "TESTE COMPLETO AUTOMÁTICO — todos os fluxos da Saga"
  registra "Health check dos 3 serviços pelo Gateway" 1
  [ "$code" = "401" ] && registra "Rota protegida bloqueia sem token (401)" 1 || registra "Rota protegida bloqueia sem token (veio $code)" 0
  registra "Login na Lambda → JWT" 1

  prepara_cadastros
  registra "Cadastro cliente/veículo (RegistryService) e serviço (Billing)" 1

  # --- Rejeição (sem pagamento) ---
  titulo "Fluxo A — Rejeição → cancelamento do pagamento"
  cria_peca "Pastilha de freio (demo)" 10 40
  abre_os_ate_aprovacao "$PECA_ID" "Pastilha de freio (demo)" 1 40
  registra "BudgetApproved → PaymentCreated (link MP gerado)" 1
  local OS_A=$OS_ID
  api POST "/api/ServiceOrders/$OS_ID/reject" >/dev/null; checa "OS rejeitada"
  sleep 3
  local st; st=$(status_de "$OS_ID"); local url; url=$(api GET "/api/ServiceOrders/$OS_ID" | jstr paymentUrl)
  [ "$st" = "7" ] && [ -z "$url" ] && registra "ServiceOrderRejected → OS Rejeitada e link removido" 1 \
                                   || registra "ServiceOrderRejected (status $st, link '$url')" 0

  # --- Caminho feliz e estorno (2 pagamentos em paralelo) ---
  titulo "Fluxo B (feliz) e Fluxo C (estorno sem estoque) — preparação"
  cria_peca "Filtro de óleo (demo)" 10 30;  local PECA_FELIZ=$PECA_ID
  abre_os_ate_aprovacao "$PECA_FELIZ" "Filtro de óleo (demo)" 1 30; local OS_FELIZ=$OS_ID
  cria_peca "Amortecedor (demo)" 1 60;     local PECA_SEM=$PECA_ID
  info "A peça do fluxo C tem 1 unidade e a OS pede 2."
  abre_os_ate_aprovacao "$PECA_SEM" "Amortecedor (demo)" 2 60;    local OS_SEM=$OS_ID
  local est_feliz est_sem
  est_feliz=$(estoque "$PECA_FELIZ"); est_sem=$(estoque "$PECA_SEM")

  local url_b url_c
  url_b=$(api GET "/api/ServiceOrders/$OS_FELIZ" | jstr paymentUrl)
  url_c=$(api GET "/api/ServiceOrders/$OS_SEM" | jstr paymentUrl)
  echo
  echo "  ${B}${Y}>>> PAGUE OS DOIS LINKS (conta de teste, sem dinheiro real):${N}"
  echo "      ${B}B (feliz)  :${N} $url_b"
  echo "      ${B}C (estorno):${N} $url_c"
  echo "      Cartão: 5031 4332 1540 6351 · CVV 123 · validade 11/30 · titular ${B}APRO${N} · CPF 12345678909"
  echo

  local ini sb sc fb=0 fc=0; ini=$(date +%s)
  while :; do
    sb=$(status_de "$OS_FELIZ"); sc=$(status_de "$OS_SEM")
    [ "$sb" = "4" ] && fb=1; [ "$sc" = "3" ] && fc=1
    printf '\r  B: %-40s C: %-40s' "$(status_nome "$sb")" "$(status_nome "$sc")"
    [ $fb = 1 ] && [ $fc = 1 ] && break
    [ $(( $(date +%s) - ini )) -ge "$WAIT_PAYMENT_SECONDS" ] && break
    sleep 3
  done
  echo

  titulo "Validação dos fluxos B e C"
  if [ $fb = 1 ]; then
    registra "B: PaymentConfirmed → ServiceOrderApproved → PartStockEnsured → Em execução" 1
    local depois; depois=$(estoque "$PECA_FELIZ")
    [ "$depois" = "$((est_feliz - 1))" ] && registra "B: estoque debitado ($est_feliz → $depois)" 1 \
                                          || registra "B: estoque debitado ($est_feliz → $depois)" 0
    api POST "/api/ServiceOrders/$OS_FELIZ/finish-execution" >/dev/null
    api POST "/api/ServiceOrders/$OS_FELIZ/deliver" >/dev/null
    [ "$(status_de "$OS_FELIZ")" = "6" ] && registra "B: OS finalizada e entregue" 1 || registra "B: OS finalizada e entregue" 0
  else
    registra "B: pagamento não confirmado (status $(status_nome "$sb"))" 0
  fi
  if [ $fc = 1 ]; then
    registra "C: estoque insuficiente → PaymentRefunded → OS volta a Aguardando aprovação" 1
    local depois_c; depois_c=$(estoque "$PECA_SEM")
    [ "$depois_c" = "$est_sem" ] && registra "C: estoque intacto ($depois_c)" 1 || registra "C: estoque intacto ($est_sem → $depois_c)" 0
  else
    registra "C: estorno não ocorreu (status $(status_nome "$sc"))" 0
  fi

  titulo "PLACAR"
  local i pass=0
  for i in "${!RES_NOMES[@]}"; do
    if [ "${RES_OK[$i]}" = "1" ]; then echo "  ${G}✔${N} ${RES_NOMES[$i]}"; pass=$((pass+1))
    else echo "  ${R}✘${N} ${RES_NOMES[$i]}"; fi
  done
  echo; echo "  ${B}$pass de ${#RES_NOMES[@]} verificações passaram.${N}"
  echo "  OSs: A=$OS_A  B=$OS_FELIZ  C=$OS_SEM"
  [ "$pass" = "${#RES_NOMES[@]}" ]
}

# ---------- main ----------
if [ -z "$AUTH_CPF" ]; then
  erro "Defina o CPF de login antes:  export AUTH_CPF=\"<cpf>\""; exit 1
fi

titulo "Oficina Mecânica — Fase 4 (microsserviços + Saga coreografada)"
info "Gateway: $GATEWAY"
etapa "Health check dos microsserviços (rotas públicas)"
for s in os billing execution; do
  code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$GATEWAY/$s/health")
  [ "$code" = "200" ] && ok "$s-service no ar" || { erro "$s-service respondeu HTTP $code"; exit 1; }
done
etapa "Segurança: rota protegida sem token"
code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$GATEWAY/api/ServiceOrders")
info "GET /api/ServiceOrders sem token → HTTP $code (esperado 401)"
etapa "Login (Lambda de autenticação por CPF → JWT)"
token >/dev/null && ok "Token JWT obtido" || exit 1

opcao="${1:-}"
if [ -z "$opcao" ]; then
  echo
  echo "  1) Caminho feliz (com pagamento)"
  echo "  2) Rejeição → cancelamento do pagamento (sem pagar)"
  echo "  3) Sem estoque → estorno automático (com pagamento)"
  echo "  4) Todos em sequência (com pausas, para o vídeo)"
  echo "  5) TESTE COMPLETO automático com placar (paga 2 links)"
  read -r -p "  Escolha: " opcao
fi
case "$opcao" in
  1) cenario_1 ;;
  2) cenario_2 ;;
  3) cenario_3 ;;
  4) cenario_1; pausa; cenario_2; pausa; cenario_3 ;;
  5|completo) teste_completo ;;
  *) erro "Opção inválida"; exit 1 ;;
esac
