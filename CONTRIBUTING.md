# Contributing

Thanks for your interest in improving the FortiAIGate Terraform + Helm deployment. This document covers how to file issues, open pull requests, and run the local checks that CI will enforce.

## Reporting issues

Please open a GitHub issue and include:

- Terraform version (`terraform version`)
- AWS region
- The relevant `.tfvars` (with secrets redacted)
- The output of `terraform plan` or the exact error message
- Whether you ran the two-step bootstrap (`-target=module.vpc -target=module.eks` first)

For security vulnerabilities, do **not** open a public issue — see [SECURITY.md](./SECURITY.md).

## Development setup

You need:

- Terraform 1.5+
- AWS CLI v2
- Helm 3
- [`tflint`](https://github.com/terraform-linters/tflint) — same checks CI runs
- [`terraform-docs`](https://terraform-docs.io/) — regenerates the README input table
- [`pre-commit`](https://pre-commit.com/) — runs all of the above before each commit

Install the pre-commit hooks once:

```bash
pre-commit install
```

## Local checks

The pre-commit configuration (`.pre-commit-config.yaml`) runs `terraform fmt`, `terraform validate`, `tflint`, and `terraform-docs` on every commit. To run them all manually:

```bash
pre-commit run --all-files
```

You can also run the individual checks:

```bash
terraform fmt -recursive -check
terraform init -backend=false
terraform validate
tflint --recursive
helm lint fortiaigate
```

CI runs the same set on every PR (`.github/workflows/terraform.yml`).

## Pull requests

- Branch from `main`. Keep PRs focused on a single concern.
- Include a `terraform plan` excerpt in the description when the change affects infrastructure resources, not just docs/CI.
- Update `CHANGELOG.md` under the `## [Unreleased]` section.
- If you change variables, run `terraform-docs` (or let pre-commit run it) so the README input table stays in sync.
- New examples go under `examples/<scenario>/terraform.tfvars` with placeholder values, plus an entry in `examples/README.md`.

## Versioning

Releases follow [Semantic Versioning](https://semver.org/):

- **MAJOR** — breaking changes to variables, resource addresses, or module boundaries
- **MINOR** — new variables/features, backwards compatible
- **PATCH** — bug fixes, doc-only changes, dependency bumps within the lock file

Tags are cut from `main` after `CHANGELOG.md` is updated to move `[Unreleased]` entries into a dated version section.
