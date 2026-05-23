terraform {
  backend "azurerm" {
    # All values supplied via -backend-config=backends/<account>.hcl at init time.
    # See backends/ directory for per-account config files.
  }
}
