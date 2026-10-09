# Production readiness follow-ups

This repository is a deployment starting point. The production example does not
establish application HA, disaster recovery, or a security baseline by itself.

- **Certificate lifecycle:** internal TLS now uses a separate generated CA and
  serving certificate in every web TLS mode. Qualify renewal/rotation and
  upgrades from existing Let's Encrypt deployments in live integration tests;
  supplied PEM web certificates require replacement and Terraform apply.
- **Build0047 qualification:** prove fresh installation, deployment licensing,
  shared/dedicated Triton/vLLM execution, model loading, and scanning on AKS.
  Qualify CPU capabilities separately. Obtain migration guidance before supporting
  in-place upgrades from build0031; the DP agent image is absent from the bundle.
- **Secret recovery:** encryption, CSRF, Redis, and PostgreSQL secrets are now
  Terraform-owned. Prove restore with the original encryption key and data;
  qualify adoption/rotation procedures for existing deployments.
- **Recovery and availability:** automate database/share backups and prove restore
  in a fresh cluster. Test node replacement, deployment license coverage, application
  replica behavior, disruption budgets, and upgrade downtime. Three app nodes do
  not make the bundled single-primary database highly available.
- **Access controls:** add configurable API access restrictions/private cluster
  support and Entra ID authentication; current providers use AKS client
  certificates. Review storage network access and workload network policies.
- **Storage lifecycle:** storage account naming currently truncates the combined
  cluster prefix and random suffix, reducing uniqueness for long cluster names.
  Introduce a migration-safe naming option that preserves the full suffix;
  changing existing account names can replace storage and destroy data.
- **Dependency lifecycle:** qualify supported AKS, cert-manager, GPU plugin, and
  container image versions together; verify registry availability and scan
  images before distributing a release. Vendoring a chart does not vendor its images.
- **Release validation:** automate live integration tests in a dedicated Azure
  subscription and publish only after the deployment checklist passes.
