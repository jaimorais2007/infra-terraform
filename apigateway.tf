# API Gateway da Fase 4: um HTTP API novo, separado do da Fase 3 (que continua no state "gateway").
# Reaproveita os Lambdas da Fase 3: autenticação por CPF (POST /authenticate) e authorizer JWT.
# As rotas de cada serviço só são criadas quando a URL dele é informada em var.service_urls.

data "aws_lambda_function" "authorizer" {
  function_name = var.authorizer_lambda_name
}

data "aws_lambda_function" "authenticate" {
  function_name = var.authenticate_lambda_name
}

locals {
  service_base_url = {
    for svc, url in var.service_urls : svc => trimsuffix(url, "/") if url != ""
  }

  # Para cada prefixo: "ANY /prefixo" e "ANY /prefixo/{proxy+}".
  proxy_routes = {
    for route in flatten([
      for svc, prefixes in var.service_routes : [
        for prefix in prefixes : [
          {
            key = "ANY ${prefix}"
            uri = "${local.service_base_url[svc]}${prefix}"
          },
          {
            key = "ANY ${prefix}/{proxy+}"
            uri = "${local.service_base_url[svc]}${prefix}/{proxy}"
          },
        ]
      ] if contains(keys(local.service_base_url), svc)
    ]) : route.key => route.uri
  }

  public_routes = {
    for key, route in var.public_routes : key => {
      method = split(" ", key)[0]
      uri    = "${local.service_base_url[route.service]}${route.path}"
    } if contains(keys(local.service_base_url), route.service)
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project}-fase4-api"
  protocol_type = "HTTP"
  description   = "Tech Challenge Fase 4 - microsservicos OS, Billing e Execution"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

# ---------- Autenticação (Lambdas da Fase 3) ----------

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "jwt-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = data.aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = 300
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowFase4ApiAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt.id}"
}

resource "aws_apigatewayv2_integration" "authenticate" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = data.aws_lambda_function.authenticate.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "authenticate" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /authenticate"
  target    = "integrations/${aws_apigatewayv2_integration.authenticate.id}"
}

resource "aws_lambda_permission" "authenticate" {
  statement_id  = "AllowFase4ApiAuthenticate"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.authenticate.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*/authenticate"
}

# ---------- Rotas protegidas dos serviços (JWT obrigatório) ----------

resource "aws_apigatewayv2_integration" "proxy" {
  for_each = local.proxy_routes

  api_id               = aws_apigatewayv2_api.this.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  integration_uri      = each.value
  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_route" "proxy" {
  for_each = local.proxy_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.proxy[each.key].id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# ---------- Rotas públicas (webhook do Mercado Pago e health checks) ----------

resource "aws_apigatewayv2_integration" "public" {
  for_each = local.public_routes

  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = each.value.method
  integration_uri    = each.value.uri
}

resource "aws_apigatewayv2_route" "public" {
  for_each = local.public_routes

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.public[each.key].id}"
}
