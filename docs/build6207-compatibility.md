# FortiAIGate 8.0.3 build 6207 AKS port

The [ACR staging procedure](registry-build6207.md) is ready. The AKS chart and Terraform defaults on `v803` still target 8.0.2 build 0055. Wait for the chart port and validation before applying the 8.0.3 settings. Use `main` for 8.0.2 deployments.

The supplied 8.0.3 chart adds Auth and its identity provisioning job, Action Guard, Observability, MCP Gateway, plugin adapters, and optional Fabric and Inference Hooks. The vendor chart also adds a read-only PostgreSQL schema check on upgrades. The vendored PostgreSQL and Redis chart versions match the existing AKS dependencies.

## Helm changes for AKS

1. Merge the vendor release changes into the maintained chart. Preserve app and GPU pool placement, the shared Azure Files claim, dedicated PostgreSQL and Redis Azure Disk claims, and existing release and Terraform resource addresses.
2. Wire new workloads and schema preflight to the existing Terraform-owned credentials and internal TLS. The vendor hook assumes a generated PostgreSQL Secret and internal TLS Secret with vendor names. Preserve the existing encryption and CSRF keys, database passwords, and deployment license data. Extend internal certificate SANs for the new service names and vLLM loopback checks.
3. Port the Auth routes to AGIC with separate backend settings for OAuth on HTTP port 9002 and SCIM on HTTPS port 9444. Carry through the private frontend selection and HTTPS redirect. Qualify SCIM backend trust and hostname verification against the Auth identity certificate, which is separate from the platform web certificate. Update cert-manager and Reloader integration for new web TLS consumers and validate the supported non-AGIC ingress configuration.
4. Update the local chart, Helm release version, Terraform defaults, examples, and render tests together. Terraform explicitly sets the application and inference tags, so changing the chart defaults alone leaves the Terraform deployment on the previous tags.
5. Render fresh installs and upgrades with CPU and shared/dedicated GPU modes, both AGIC exposure modes, and generated, supplied, and cert-manager web TLS. Compare resource names, workload selectors, and PVC specs with build 0055. Run isolated Terraform validation and review a full plan before testing in AKS.

## Existing deployment validation

Back up PostgreSQL, Redis, Azure Files, Terraform state, and application Secrets before testing the upgrade against a restored deployment. Keep schema preflight enabled. If it reports a required schema bridge, obtain Fortinet's supported procedure before attempting the cutover. The vendor chart archive references a bridge script and does not include it. Validate login, AGIC backend health, licensing, and inference on AKS before using the upgrade in production.
