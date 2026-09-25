# Terraform-managed Application Gateway for INTERNAL (private-frontend) ingress.
#
# With internal = false the AGIC add-on creates its own gateway (greenfield, in
# the AKS node resource group) with a PUBLIC frontend only — see aks.tf. That
# gateway has no private frontend, and AGIC silently ignores an Ingress
# annotated use-private-ip on a gateway without one (NoPrivateIP warning), so
# internal = true cannot work against it.
#
# With internal = true this file creates the gateway instead, with BOTH a public
# frontend (Application Gateway v2 requires a public IP; no listener is bound to
# it) and a static private frontend in the appgw subnet. The add-on is pointed
# at it via gateway_id (brownfield), and local.internal_appgw_values (helm.tf)
# annotates the Ingress so AGIC binds every listener to the private IP.
#
# Choose the mode at deploy time. Flipping `internal` on a live cluster
# re-points the add-on at a different gateway (and leaves the previous one
# orphaned until it is deleted); see docs/application-gateway-dns-tls.md.

locals {
  appgw_byo               = var.agic_enabled && var.internal
  appgw_private_ip        = var.appgw_private_ip != "" ? var.appgw_private_ip : cidrhost(var.appgw_subnet_cidr, -2)
  appgw_trusted_root_name = "fortiaigate-ca"
}

resource "azurerm_public_ip" "appgw" {
  count = local.appgw_byo ? 1 : 0

  name                = "${var.cluster_name}-appgw-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "this" {
  count = local.appgw_byo ? 1 : 0

  name                = "${var.cluster_name}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  # Matches what the add-on creates in greenfield mode.
  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  # Pin a current policy explicitly; the service default has been the retired
  # TLS 1.0/1.1 AppGwSslPolicy20150501, which new gateways may be refused with.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  # The per-deployment CA from tls.tf, so the gateway trusts the HTTPS backends
  # (without it every backend is unhealthy -> 502). Referenced from the Ingress
  # by local.appgw_trusted_root_values in helm.tf. Not needed with Let's Encrypt
  # (a well-known CA chain). Terraform keeps managing this block -- AGIC only
  # references trusted roots by name, it never writes them.
  dynamic "trusted_root_certificate" {
    for_each = var.letsencrypt_enabled ? [] : [1]
    content {
      name = local.appgw_trusted_root_name
      data = base64encode(tls_self_signed_cert.ca[0].cert_pem)
    }
  }

  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  # v2 requires a static private frontend address from the gateway subnet.
  frontend_ip_configuration {
    name                          = "appgw-private-frontend"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.appgw_private_ip
  }

  # Placeholder routing config: the API requires at least one listener/rule to
  # create a gateway. AGIC replaces all of it from the Ingress on its first sync.
  # The placeholder listener sits on the PRIVATE frontend so nothing is ever
  # served on the public IP, even before AGIC takes over.
  frontend_port {
    name = "placeholder-port"
    port = 80
  }

  backend_address_pool {
    name = "placeholder-pool"
  }

  backend_http_settings {
    name                  = "placeholder-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
  }

  http_listener {
    name                           = "placeholder-listener"
    frontend_ip_configuration_name = "appgw-private-frontend"
    frontend_port_name             = "placeholder-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "placeholder-rule"
    rule_type                  = "Basic"
    priority                   = 20000
    http_listener_name         = "placeholder-listener"
    backend_address_pool_name  = "placeholder-pool"
    backend_http_settings_name = "placeholder-settings"
  }

  # AGIC owns the routing configuration (and stamps its own tags) from here on.
  # Without this, every terraform apply would revert AGIC's config to the
  # placeholders and take the ingress down until AGIC re-syncs.
  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_port,
      http_listener,
      probe,
      redirect_configuration,
      request_routing_rule,
      rewrite_rule_set,
      ssl_certificate,
      url_path_map,
      tags,
    ]
  }
}

# In greenfield mode AKS grants the add-on identity rights on the gateway it
# creates. For a brought-in gateway it does not: AGIC needs Contributor on the
# gateway to push config and Reader on its resource group, or it logs
# authorization failures and the Ingress never gets listeners. The subnet
# Network Contributor grant it needs in both modes lives in aks.tf.
resource "azurerm_role_assignment" "agic_appgw_contributor" {
  count = local.appgw_byo ? 1 : 0

  scope                            = azurerm_application_gateway.this[0].id
  role_definition_name             = "Contributor"
  principal_id                     = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "agic_rg_reader" {
  count = local.appgw_byo ? 1 : 0

  scope                            = azurerm_resource_group.this.id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  skip_service_principal_aad_check = true
}
