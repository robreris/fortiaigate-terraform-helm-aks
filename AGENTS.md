# Repository guidance

This guidance applies to coding agents working in this repository.

## Scope and constraints

- This repository deploys FortiAIGate on Azure AKS using Terraform and local Helm charts. Application source and container images are maintained elsewhere.
- Preserve the AKS chart's ingress, TLS, licensing, storage, and GPU placement patches when importing upstream builds. Do not replace `fortiaigate/` wholesale or assume it matches the EKS chart.
- Keep generated Terraform resource addresses stable during upgrades. Terraform owns PostgreSQL credentials and internal TLS; web TLS uses generated material, supplied PEM files, or cert-manager.
- Keep shared RWX storage on Azure Files and database storage on dedicated Azure Disks. Build0047 uses deployment licenses: preserve app/GPU pool placement without node-license affinity, and keep the GPU pool's explicit `gpu_driver = "Install"` setting.
- Terraform owns the credential encryption key, CSRF key, and Redis password as well as PostgreSQL credentials. Preserve their resource addresses and never regenerate them against retained data.
- Inspect value precedence in `helm.tf` before changing chart defaults or adding overrides. Later values win, and Terraform `set` blocks have final precedence.
- Keep deployment procedures and troubleshooting in `docs/`; link to them here instead of duplicating them. Update the relevant docs and changelog when behavior changes.
- Keep credentials, licenses, PEM keys, kubeconfigs, local tfvars, state, plans, and rendered manifests out of version control.

## Where to read

- [README](README.md): deployment overview, two-step bootstrap, subscription layout, variables, and teardown.
- [Contributing](CONTRIBUTING.md): local checks, generated README tables, and PR requirements.
- [Operations and upgrades](docs/operations.md): credential adoption, licensing, storage constraints, and rollout behavior.
- [Application Gateway, DNS, and TLS](docs/application-gateway-dns-tls.md): gateway ownership, private ingress, and backend trust.
- [Supplied certificates](docs/tls-supplied.md) and [Let's Encrypt](docs/tls-letsencrypt.md): web/internal TLS separation and renewal.
- [GPU compatibility](docs/gpu-triton-compatibility.md), [registry setup](docs/registry-and-images.md), [permissions](docs/permissions-preflight.md), and [remote state](docs/remote-state.md): deployment prerequisites.
- [Testing](docs/testing.md) and [roadmap](ROADMAP.md): validation coverage and remaining production gaps.

## Validation

Use the checks in [CONTRIBUTING.md](CONTRIBUTING.md) appropriate to the change.
Run Terraform validation and mocked tests from an isolated checkout or temporary
directory so ignored local tfvars and remote state do not affect results.
Use the vendored subcharts for Helm checks. Offline checks do not establish
runtime compatibility; record live deployment results separately in
[the testing guide](docs/testing.md).
