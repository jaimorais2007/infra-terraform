# NodePort do Traefik: a porta 80 do host esta ocupada pela API da Fase 2/3.
# Os demais servicos entram aqui quando estiverem publicados no cluster.
service_urls = {
  os        = ""
  billing   = ""
  execution = "http://34.239.92.126:32276/execution"
}
