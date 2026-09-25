# Changelog

## Unreleased

- Replace the bare self-signed serving cert with one signed by a per-deployment CA (`tls.crt` carries the chain); in internal mode upload the CA to the gateway as a trusted root and annotate the Ingress, removing the self-signed 502. New `tls_ca_certificate` output for client trust stores.
- Roll license-manager when license file contents change (`license.checksum`), mount the ConfigMap named by `license.existingConfigMap`, and list `app_node_vm_size` in the tfvars examples.
- Make `internal = true` a complete private-ingress deployment: Terraform creates the Application Gateway with a static private frontend (`appgw_private_ip`), points the AGIC add-on at it, grants the add-on identity access, and exposes `appgw_private_ip` as an output. Public mode is unchanged.
- Own the PostgreSQL credential Secret in Terraform (`postgresql.auth.existingSecret`) so a Helm uninstall/reinstall can no longer regenerate the password against a retained database volume.
- Upgrade the AKS Helm chart to the build0031 (8.0.1) model configurations, scanner/core settings, and ingress routes while retaining AKS-specific storage, licensing, TLS, and GPU placement; make build0031 the Terraform image-tag default and trigger Helm upgrades when local chart content changes.
- Align the registry guide and tfvars examples with the build0031 chart's eight image repositories and three independent tags; verify the downloaded Docker archive manifests and extracted Helm chart, and document external database images.
- Let Terraform set the independent Triton server and model image tags.
- Keep the licensed GPU pool at one node and ignore autoscaler-owned count drift.
- Supply HTTPS AGIC defaults and remove incorrect global health probes from examples.
- Wait for managed ACR and AGIC role assignments before installing FortiAIGate.
- Match Azure Files StorageClass SKU to the selected account tier and reject incompatible account kinds.
- Reject fractional app node counts and blank image repositories.
- Test CPU/GPU Helm rendering, storage, ingress readiness probes, and ACME issuer configuration in CI using vendored dependencies.
- Correct Azure contribution instructions and document testing and production limitations.
