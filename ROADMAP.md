# Production readiness follow-ups

This repository is a deployment starting point. The production example does not
establish application HA, disaster recovery, or a security baseline by itself.

- **Database TLS:** Let's Encrypt mode currently disables PostgreSQL and Redis
  TLS. Use a separate internal CA and certificates for database traffic, with
  matching client trust and renewal handling. Multiple licensed app nodes mean
  traffic can cross nodes; colocation must not be assumed.
- **Stable secrets:** the shared chart generates a new CSRF key on each render
  unless `fortiaigate.env.csrfSecretKey` is supplied. Preserve the existing secret
  on upgrade or support an externally managed secret. Coordinate shared chart
  fixes with EKS and OCI; chart contents already differ between these repos.
- **Recovery and availability:** automate database/share backups and prove restore
  in a fresh cluster. Test node replacement, license reassignment, application
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
