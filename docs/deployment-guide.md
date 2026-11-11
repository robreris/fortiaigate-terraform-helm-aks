# Deployment and configuration

Start with the [README quickstart](../README.md#quickstart). Use [operations and upgrades](operations.md) for credential adoption and troubleshooting, [technical notes](technical-notes.md) for implementation constraints, and [staged teardown](teardown.md) for removal.

## Architecture

Application services, license manager, PostgreSQL, and Redis use the app node pool. The optional tainted GPU pool runs Triton and vLLM in shared or dedicated mode. Application Gateway provides HTTPS ingress; generated, supplied PEM, and cert-manager web certificates are supported independently of internal service TLS.

Shared application data uses an Azure Files RWX claim. PostgreSQL and Redis each use dedicated Azure Disk RWO claims. Terraform owns database passwords, Redis authentication, the master encryption key, and CSRF key. Deployment licenses are uploaded through the authenticated admin API and stored in PostgreSQL.

## Bootstrap and updates

For 8.0.3 preparation on `v803`, [stage the images in ACR](registry-build6207.md) and review the [AKS chart port status](build6207-compatibility.md) before changing deployment tfvars.

The first deployment requires the infrastructure targets in the quickstart before the full application apply so the Kubernetes and Helm providers can reach AKS. Licensing requires no intermediate node discovery. Subsequent updates normally use a full plan/apply with the same backend and tfvars; targeting is reserved for initial bootstrap and staged teardown.

For build0047 to build0055, follow [the port and upgrade notes](build0055-compatibility.md). For older 8.0.1 data, first read [the migration prerequisites](upgrade-8.0.1-to-8.0.2.md); a successful infrastructure plan does not qualify database migration.

## Common variables

| Variable | Default | Notes |
|----------|---------|-------|
| `location` | `eastus` | Azure region. Must have quota for the chosen VM sizes — A10/A100 GPU families are request-only (default 0) in most regions. |
| `cluster_name` | `fortiaigate` | Used as the AKS name, DNS prefix, and (after stripping) the storage account name prefix. |
| `app_node_count` | `1` | Fixed application pool size, independent of deployment licenses. |
| `app_node_max_pods` | `110` | Per-node pod cap. Account for service/system pods and Azure CNI subnet capacity. |
| `gpu_enabled` | `false` | Adds the GPU pool and device plugin. Without it, vLLM is disabled and POLICY detectors fail closed; CPU-only capabilities are unqualified. |
| `gpu_node_vm_size` | `Standard_NV36ads_A10_v5` | A10 (24 GB, SM 86). Must be a Fortinet-supported GPU with ≥24 GB VRAM and SM 75+; the V100 fails. |
| `acr_id` | `""` | Set to the ACR resource ID to codify the kubelet `AcrPull` grant; leave empty if managed elsewhere. |
| `image_tag` | `V8.0.2-build0055` | Application image tag; does not set Triton image tags. |
| `triton_image_tag` | `25.11-onnx-trt-agt-rpt-s1` | `custom-triton` tag when GPU is enabled. |
| `triton_models_image_tag` | `0.0.5-s1` | `faig-models` tag shared by Triton and vLLM. |
| `db_storage_class` | `managed-csi` | Block (RWO) StorageClass for PostgreSQL/Redis — they cannot run on the shared Azure Files (SMB) class. |
| `agic_enabled` | `true` | Disable to use ingress-nginx or web_app_routing instead. |
| `ingress_class` | `azure-application-gateway` | Must match the installed controller. |
| `internal` | `false` | False: the AGIC add-on creates a public-only gateway; point DNS at its public IP. True: Terraform creates the gateway with a static private frontend, points AGIC at it, and binds all listeners to the private IP (VNet/VPN access only). Decide before the first deploy — see [the gateway guide](application-gateway-dns-tls.md). |
| `appgw_private_ip` | `""` | Private frontend IP when `internal = true`. Empty = second-to-last address of `appgw_subnet_cidr` (e.g. `10.0.64.254`). |
| `ingress_host` | `""` | Hostname for the ingress rule, e.g. `fortiaigate.example.com`. Set this before creating DNS/TLS for a public UI. |
| `image_repository` | *(required)* | e.g. `myregistry.azurecr.io/fortiaigate`. |
| `vllm_image_tag` | `0.28.0-rpt-s1` | vLLM serving and GPU-probe image. |
| `vllm_gpu_attach` | `shared` | Explicit shared/dedicated GPU layout; shared runtime needs live AKS qualification. |
| `gpu_node_count` | `1` | Fixed GPU pool size; dedicated mode normally needs at least two one-GPU nodes. |

Full list in [the Terraform reference](terraform-reference.md).

The Terraform defaults and tfvars examples select the build0055 image set.
Set all four image tag variables explicitly when moving to a later build.
This repository does not bundle images; the
[registry guide](registry-and-images.md) records the names and tags
verified from the supplied build0055 archives.

The build0055 port targets fresh installations. FortiAIGate 8.0.2 uses
LLM gateway/guardrail services in place of the earlier core/scanners and routes `/ai` to the gateway, `/api/` to API,
and `/ui` plus `/` to webui. It includes vLLM and deployment licensing.
Existing deployment upgrades, database migration, and licensing conversion are
not qualified; use [the 8.0.1-to-8.0.2 upgrade guide](upgrade-8.0.1-to-8.0.2.md)
and [the build0055 port notes](build0055-compatibility.md).
Offline tests do not establish live AKS or model compatibility.

Terraform owns the local `fortiaigate` Helm release. `helm.tf` passes the
variables above into chart values; its `set` blocks take precedence over
`extra_values_files`. Terraform also overrides extra values for GPU placement,
Azure Disk database storage, AGIC annotations, TLS, stable application secrets, and app/GPU pool placement.
Use `extra_values_files` for chart settings without a dedicated Terraform
variable, such as per-service resource requests or replica counts. Changing the
chart's defaults alone does not change values already supplied by Terraform.

## GPU tuning

`gpu_tuning_profile = "auto"` selects the `a10` profile for Azure VM names containing `_A10_`, including the default `Standard_NV36ads_A10_v5`. It preserves one DLP model instance, 12/8 GiB Triton/vLLM host memory requests, 25/24 GiB limits, 64 vLLM concurrent sequences, one API process, and an 80% vLLM GPU budget. The limits can exceed concurrent available memory on smaller nodes; validate model startup and inference on the actual SKU. Host RAM and GPU VRAM are separate budgets.

Other VM families retain vendor chart defaults; no runtime compatibility is implied. Select `"chart"` to disable the automatic profile, or `"a10"` to explicitly request it. Omitted `gpu_tuning` fields inherit profile/chart values:

```hcl
gpu_enabled        = true
gpu_tuning_profile = "auto"
gpu_tuning = {
  vllm_max_num_seqs     = 32
  triton_memory_limit  = "25Gi"
}
```

The optional fields cover Triton/vLLM memory requests and limits, DLP instances and batch size, vLLM concurrency, API process count, context length, and GPU utilization. See [the generated inputs](terraform-reference.md#inputs) and [GPU compatibility](gpu-triton-compatibility.md). Advanced `vllm.extraArgs` flags take priority over the chart's corresponding structured engine knobs; remove duplicate legacy flags when using `gpu_tuning`.
