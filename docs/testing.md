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
```

The Helm suite renders representative AKS values and checks CPU/GPU behavior,
licensed hostname affinity, independent app/Triton image tags, backend readiness
paths, separate database disks,
external TLS secret references, and staging/production Certificate resources.
It also verifies missing issuer inputs fail rendering. It uses the committed
subcharts without refreshing dependencies. It does not exercise Terraform value
merging, Azure permissions, image availability, admission controllers, or actual
certificate issuance.

## Live deployment tests

Use a dedicated test subscription/resource group and follow the README's
two-step bootstrap. These operations create billable Azure resources.

1. Check regional AKS version availability, GPU quota, image availability, and
   principal permissions. Set `acr_id` if this stack should manage image pull access.
2. Start with CPU-only (`gpu_enabled = false`) and a licensed app node. Verify
   all pods become ready, shared and database PVCs bind, and `/ui` is reachable.
   Self-signed TLS requires explicit Application Gateway backend trust; follow
   [the TLS guide](application-gateway-dns-tls.md) before diagnosing HTTP 502s.
3. Enable the GPU pool using the bootstrap targets, record its actual hostname,
   and populate its license before the full apply. Verify Triton schedules on
   that node and a request using GPU-backed scanning completes.
4. Run a second plan with the same tfvars. Investigate unexpected replacement or
   perpetual updates, especially GPU nodes and storage. The GPU minimum is now
   one while enabled, preserving the node during idle/bootstrap periods and
   continuing to incur its VM cost. Node repair/upgrade can still replace it.
5. Exercise Let's Encrypt staging then production in a disposable DNS name.
   Confirm Certificate readiness, gateway health, and pod reload after secret
   changes. Review the database TLS limitation in [ROADMAP.md](../ROADMAP.md).
6. Back up and restore database data and the shared file data. Test a node
   replacement and license reassignment before planning a production upgrade.
7. Follow the README teardown sequence; check for remaining disks/shares and
   confirm retained data matches expectations before deleting the resource group.

## Existing deployment review

Review a saved plan before applying these changes. GPU `min_count` changes from
zero to one. Standard storage now requests `Standard_LRS`; StorageClass parameters
may require replacement if an existing class used the wrong SKU. Existing PVCs
are not migrated. No storage account naming migration is included in this pass.
Examples remove global AGIC probes; make the same correction in your ignored
local tfvars. Each backend has a different readiness endpoint.

The 8.0.1/build0031 chart upgrade also changes the app and Triton image tags,
core/scanner environment values, and Triton model configuration. Its ingress
routes `/ui` to webui, `/api/` to api, and `/` to core. Terraform passes a chart
digest to the Helm release so local chart edits produce an upgrade plan. Test
both a first install and an upgrade with real licenses and pushed images before
using this chart in production; the offline suite cannot confirm runtime model
loading, scanning, or data migration.

Azure behavior references: [cluster autoscaler](https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler-overview)
and [Azure Files CSI provisioning](https://learn.microsoft.com/en-us/azure/aks/azure-csi-files-storage-provision).

## Distribution

Distribute a reviewed Git commit/tag, including `.terraform.lock.hcl`, the Helm
lockfile, and vendored subcharts. Use placeholder tfvars examples; exclude local
licenses, keys, kubeconfigs, state, plans, and rendered manifests. Build source
archives from committed files (`git archive`) rather than archiving the working
directory. Record the tested Azure region, AKS version, image tag, TLS mode,
CPU/GPU results, and known limitations in the release notes.
