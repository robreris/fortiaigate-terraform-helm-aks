# Testing and distribution checklist

## Offline checks

Use Terraform, Helm 3, Python 3.10+, and TFLint v0.53.0 as described in
[CONTRIBUTING.md](../CONTRIBUTING.md). Run checks from a clean checkout so local
tfvars and initialized remote state do not affect results:

```bash
terraform fmt -check -recursive
terraform init -backend=false -lockfile=readonly
terraform validate
tflint --init
tflint --recursive --format compact
python3 -m pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v
python3 scripts/test_tls.py # Terraform 1.7+; mocked tests in an isolated checkout
```

The Helm suite renders representative AKS values and checks CPU/GPU behavior,
deployment licensing and app/GPU placement, independent app/Triton image tags, backend readiness
paths, separate database disks,
shared/dedicated inference topology, separate web/internal TLS secrets and rollout checksums, and staging/production Certificate resources.
The certificate preflight tests use real temporary keys/certificates. The mocked
Terraform suite covers generated, supplied public/private, and Let's Encrypt
modes, as well as invalid input combinations.
It also verifies missing issuer inputs fail rendering. It uses the committed
subcharts without refreshing dependencies. It does not exercise Terraform value
merging, Azure permissions, image availability, admission controllers, or actual
certificate issuance.

## Live deployment tests

Previous repository notes recorded a clean 8.0.0 deployment on 2026-05-28 using
AKS 1.35, one licensed app node with a 110-pod cap, one A10 GPU node, and
PostgreSQL on `managed-csi`. This is historical evidence for that configuration;
it does not validate the 8.0.1/build0031 chart or the current TLS changes.

Use a dedicated test subscription/resource group and follow the README's
two-step bootstrap. These operations create billable Azure resources.

1. Check regional AKS version availability, GPU quota, image availability, and
   principal permissions. Set `acr_id` if this stack should manage image pull access.
2. Start with CPU-only (`gpu_enabled = false`) and an app node. Verify
   all pods become ready, shared and database PVCs bind, and `/ui` is reachable.
   Self-signed TLS requires explicit Application Gateway backend trust; follow
   [the TLS guide](application-gateway-dns-tls.md) before diagnosing HTTP 502s.
3. Enable the GPU pool using the bootstrap targets, choose shared/dedicated topology and sufficient GPU capacity
   before the full apply. Verify Triton schedules on
   the GPU pool and both DLP and POLICY requests complete; check
   license onboarding, metering, model loading, device visibility, and memory.
4. Run a second plan with the same tfvars. Investigate unexpected replacement or
   perpetual updates, especially GPU nodes and storage. The GPU minimum is now
   one while enabled, preserving the node during idle/bootstrap periods and
   continuing to incur its VM cost. Node repair/upgrade can still replace it.
5. Exercise Let's Encrypt staging then production in a disposable DNS name.
   Upload the deployment license through the admin API. Confirm Certificate
   readiness, gateway health, and pod reload after secret
   changes. Verify PostgreSQL/Redis TLS against the separate internal CA. Test supplied
   public/private certificates and replacement using [the supplied TLS guide](tls-supplied.md).
   Verify gateway/API-to-guardrail and license-manager RPC/database trust when
   web and internal certificates have different issuers.
6. Back up and restore database data and the shared file data. Test a node
   replacement and deployment license coverage before planning a production upgrade.
7. Follow the README teardown sequence; check for remaining disks/shares and
   confirm retained data matches expectations before deleting the resource group.

## Existing deployment review

Use the [8.0.1-to-8.0.2 upgrade guide](upgrade-8.0.1-to-8.0.2.md) for the
branch comparison, staged secret adoption, and rehearsal/recovery checklist.
That documentation does not establish a qualified live upgrade.

Build0047 targets fresh installations. Database migration and conversion from
node-keyed licensing are not qualified; use [the compatibility audit](build0047-compatibility.md).

Review a saved plan before applying changes. Application services, licensing,
encryption, and ingress routes change with build0047. Existing PVCs and database
schemas are not migrated by this port. Retain credential resource addresses,
back up data and keys, and qualify application schema/license conversion before
reusing old storage. Each ingress backend has a different readiness endpoint;
remove global AGIC probe-path overrides from local tfvars. Terraform passes a
chart digest, including files used by the GPU probe, so local edits produce an
upgrade plan. Offline suites cannot confirm runtime scanning or data migration.

Azure behavior references: [cluster autoscaler](https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler-overview)
and [Azure Files CSI provisioning](https://learn.microsoft.com/en-us/azure/aks/azure-csi-files-storage-provision).

## Distribution

Distribute a reviewed Git commit/tag, including `.terraform.lock.hcl`, the Helm
lockfile, and vendored subcharts. Use placeholder tfvars examples; exclude local
licenses, keys, kubeconfigs, state, plans, and rendered manifests. Build source
archives from committed files (`git archive`) rather than archiving the working
directory. Record the tested Azure region, AKS version, image tag, TLS mode,
CPU/GPU results, and known limitations in the release notes.

## Build0047 offline port status

The AKS port preserves app/GPU placement, database disks, Terraform-owned
credentials/encryption/CSRF, and independent web/internal TLS. Tests cover new
ingress routes and probes, shared/dedicated GPU shapes, image defaults, legacy
license rejection, and explicit GPU capacity. No live AKS results are recorded
for build0047. CPU-only POLICY detectors fail closed without vLLM; do not treat
a successful CPU render as proof of full scanning capability.

On 2026-10-09 the port passed 19 Python/Helm/certificate tests, 15 mocked
Terraform runs, isolated Terraform validation, TFLint 0.53.0/Azure ruleset 0.27.0,
formatting, documentation link checks, and proxy/GPU-probe syntax checks.
Existing Azure provider deprecation warnings are still present.
