# Changelog

## Unreleased

- Add the verified FortiAIGate 8.0.3 build 6207 inventory, ACR upload script, staging instructions, and AKS chart port notes.

- Automatically install generated or supplied private web CA roots on the public AGIC gateway with a named AzAPI update before Helm installs ingress; preserve the add-on gateway, other roots, and routing ownership. Add AzAPI 2.9, regression coverage, and upgrade/permission guidance.
- Fix shared Azure Files provisioning permissions in existing-network mode by granting the user-assigned AKS control-plane identity; retain the storage role assignment's resource address and add regression assertions for both network modes.
- Port the supplied FortiAIGate 8.0.2/build0055 chart changes and image defaults selectively; add verified chart/image fingerprints, GPU profiles, DLP batching controls, and gateway Base URL keepalive configuration.
- Preserve AKS ingress/probes, app/GPU placement and explicit driver install, Azure Files shared storage, Azure Disk databases, and Terraform-owned credentials. Add automatic Azure A10 inference tuning and validated explicit overrides.
- Issue an independent internal leaf certificate with the effective PostgreSQL username as CN while preserving existing CA, web TLS, Secret, storage, network and credential resource addresses. Internal databases/clients roll on this transition.
- Restore external-network validation fixes, eight mocked scenarios, and the missing existing-network guide from the maintained network implementation.
- Run CI for `main` and `v8.0.2`; validate actual Terraform GPU values through Helm and check local documentation links.
- Separate deployment configuration, technical notes, staged teardown, and generated Terraform reference from the README; correct the security policy for Azure and remove sibling-repository references.


- Document the 8.0.1/build0031 to 8.0.2/build0047 branch comparison, live secret adoption, migration prerequisites, staged cutover, and recovery limits.

- Support externally owned VNets and AKS/Application Gateway subnets, pre-grant AKS network access, and configure Kubernetes service/DNS ranges. Preserve managed-network state with moved declarations.

- Port FortiAIGate 8.0.2/build0047 for fresh AKS installations: LLM gateway/guardrail services, explicit shared/dedicated Triton/vLLM layouts, and deployment licensing.
- Preserve AKS ingress/probes, app/GPU placement, Azure Disk databases, and separate internal TLS; manage encryption, CSRF, and Redis credentials in Terraform.
- Add build0047 Helm/Terraform contracts and document live qualification and upgrade gaps.
- Replace duplicated Claude-specific guidance with shared `AGENTS.md` instructions and an operations/upgrade guide.
- Support supplied PEM web/API certificates and optional private root CA trust for Application Gateway.
- Separate internal service/database TLS from web certificates and retain database TLS in Let's Encrypt mode.
- Add certificate preflight validation, mocked Terraform TLS tests, and Helm checks for independent secrets and rollouts.

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
