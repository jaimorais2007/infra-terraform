# Elastic IP fixo para a EC2 "tech-challenge-fase2" (k3s), que já existia das Fases 2/3
# (a instância em si não é gerenciada por este Terraform). Sem IP fixo, o IP público muda a
# cada reinício da instância, quebrando o certificado TLS do k3s (tls-san), o kubeconfig usado
# no CI/CD e as rotas deste API Gateway para os microsserviços.
#
# O EIP foi alocado e associado manualmente pelo console AWS em 29/10/2026 (allocation id
# eipalloc-06783b7799a71285d) antes deste PR existir — por isso é referenciado via data source
# em vez de "resource", pra não tentar criar um segundo EIP e deixar o primeiro órfão (cobrando
# por ficar sem associação).
data "aws_eip" "k3s_cluster" {
  id = "eipalloc-06783b7799a71285d"
}
