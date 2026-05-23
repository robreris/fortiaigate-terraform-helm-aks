# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report security issues directly to Fortinet PSIRT:

- Web: <https://www.fortiguard.com/psirt>
- Email: <psirt@fortinet.com>

Include:

- The affected file(s) and Terraform version
- A description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- Your suggested remediation, if any

Fortinet PSIRT will acknowledge your report within 5 business days and coordinate disclosure.

## Scope

This policy covers the Terraform and Helm code in this repository, including:

- Default IAM policies attached by the modules
- Default network exposure (security groups, ALB schemes, EKS endpoint access)
- Default secret handling (TLS certificates, license storage)

It does **not** cover vulnerabilities in upstream dependencies (Terraform providers, third-party Helm charts, AWS-managed addons) — report those to the relevant upstream project. It also does not cover FortiAIGate container image vulnerabilities, which are reported through the standard Fortinet support channels.

## Production hardening

The defaults in this repository favor ease of evaluation, not production security posture. Before deploying to a production environment, review at minimum:

- `cluster_endpoint_public_access` — `true` by default; restrict to known CIDRs or disable in favor of private endpoint access
- `single_nat_gateway` — `true` by default; set to `false` for multi-AZ resilience
- Self-signed TLS in `tls.tf` — replace with ACM or cert-manager-issued certificates
- EFS encryption (`efs_encrypted`) — defaults to `true`, but uses the AWS-managed key; use a customer-managed KMS key for production
- IAM scopes attached via the EKS, EFS CSI, and ALB controller IRSA modules — review the AWS-managed policies used and apply least-privilege overrides where appropriate
