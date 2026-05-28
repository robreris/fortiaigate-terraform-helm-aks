# GPU compatibility for Triton (Azure)

Triton is the only GPU workload in this stack. The bundled image
(`custom-triton:25.11-onnx-trt-agt`, set in
`fortiaigate/templates/triton-server.yaml`) ships **TensorRT 10.x**, which
**dropped support for NVIDIA Volta (compute capability SM 70)**. On a Volta GPU
the Triton pod crashes at engine-build time with:

```
IBuilder::buildSerializedNetwork: Error Code 9: API Usage Error
(Target GPU SM 70 is not supported by this TensorRT release.)
```

This is **not** a regression — the `25.11` tag has been pinned since the chart's
first commit. It only surfaces on Azure because of the GPU the AKS stack was
scaffolded with.

## Why AWS (EKS) never hit this

The Helm chart is intentionally identical between the EKS and AKS stacks, so the
Triton image is the same in both. The difference is the GPU hardware each cloud
was pointed at:

| Stack | Default GPU node | GPU | Compute | TensorRT 10 |
|-------|------------------|-----|---------|-------------|
| AWS / EKS | `g5.2xlarge` | A10G | SM 86 (Ampere) | ✅ works |
| Azure / AKS | `Standard_NC6s_v3` | V100 | SM 70 (Volta) | ❌ rejected |

The fix is to put AKS on a GPU that satisfies **both** constraints below — the
same class of card AWS already runs — by changing `var.gpu_node_vm_size`.

## The two constraints the GPU must satisfy

1. **TensorRT 10 (the Triton image):** compute capability **SM 75 or newer**
   (Turing+). Rules out Volta (V100), Pascal, Maxwell, Kepler.
2. **FortiAIGate hardware spec** ([8.0.0 deployment guide](https://docs.fortinet.com/document/fortiaigate/8.0.0/fortiaigate-administration-guide/512071/fortiaigate-deployment)):
   supported GPU models are **NVIDIA L4, A10, A100**, each with **≥ 24 GB
   VRAM** (driver 535+). Per-GPU minimum is "1× GPU with 24 GB VRAM (e.g. L4)".

> **The T4 does NOT qualify.** It is SM 75 (passes constraint 1) but has only
> **16 GB VRAM** and is **not on Fortinet's supported list** (fails constraint 2).
> The current V100 fails both (SM 70 and 16 GB). Do not use either.

## Supported GPU SKUs on Azure

Of Fortinet's three supported models, **L4 is not offered as an Azure VM SKU in
westus**, leaving **A10** and **A100**. All SKUs below are offered in westus with
no SKU-level restriction; the only gate is **quota** (see below).

| SKU | vCPU | GPU | VRAM | RAM | Notes |
|-----|------|-----|------|-----|-------|
| `Standard_NV36ads_A10_v5` | 36 | 1× A10 | **24 GB** | 440 GiB | **Recommended.** Meets the 24 GB spec; same GPU class as the AWS `g5.2xlarge` (A10G) that already works. |
| `Standard_NC24ads_A100_v4` | 24 | 1× A100 | 80 GB | 220 GiB | Compliant but premium silicon — overkill for a 24 GB need and pricier per hour. |

> The smaller `NVads_A10_v5` SKUs (`NV6/12/18ads_A10_v5`) expose only a
> **fractional** A10 vGPU (4–12 GB) — below the 24 GB spec. The full 24 GB card
> requires `NV36ads_A10_v5`.

**Recommendation:** `Standard_NV36ads_A10_v5`. It is on Fortinet's supported
list, meets the 24 GB VRAM minimum, satisfies TensorRT 10 (SM 86), and matches
the A10G the EKS stack runs successfully.

## Quota increase to request

Every GPU family that has quota in `westus` is Volta or older (V100, P100, K80,
P40, M60 — all rejected by TensorRT 10). Every supported family (A10, A100, and
the also-compatible T4/H100) sits at **0 vCPU quota**. So changing the VM size
alone will fail at apply with a quota error — you must request quota first.

Switching regions does **not** avoid this: the supported families default to 0
quota subscription-wide — verified 0/0 across westus, westus2, westus3, eastus,
eastus2, centralus, and southcentralus. The quota request is unavoidable.

Request in the **Azure portal → Quotas → Compute**, or via support, for region
**West US (`westus`)**:

| If you choose | Quota family to raise | Suggested new limit |
|---------------|-----------------------|---------------------|
| **A10 (`NV36ads_A10_v5`) — recommended** | **Standard NVADSA10v5 Family vCPUs** | **36 vCPUs** (one full-A10 node) |
| A100 (`NC24ads_A100_v4`) | **Standard NCADS_A100_v4 Family vCPUs** | **24 vCPUs** (one A100 node) |

Check current quota at any time:

```bash
az vm list-usage --location westus -o table | grep -iE 'NVADSA10v5|NCADS_A100_v4'
```

## Applying the change after quota lands

1. Set the new SKU in `tfvars/<subscription>.tfvars`, e.g.:

   ```hcl
   gpu_node_vm_size = "Standard_NV36ads_A10_v5"
   ```

2. `gpu_node_vm_size` is **ForceNew** on the GPU node pool, so this **replaces**
   the pool. The replacement node gets a **new VMSS name**
   (`aks-gpu-<newhash>-vmss000000`), which **re-keys node-affinity licensing**.
   After the new node joins, update the GPU entry in `var.licenses` to the new
   node name and re-apply — same post-apply step as the initial deploy. See the
   node-keyed licensing notes in `CLAUDE.md`.

3. Confirm the node's GPU and that Triton's TensorRT engine builds:

   ```bash
   kubectl get nodes -L node.kubernetes.io/instance-type,nvidia.com/gpu.product
   kubectl logs -n fortiaigate -l app.kubernetes.io/name=triton --tail=50
   ```

## If a supported GPU is not an option

If quota can't be obtained, the alternatives are:

- **Volta-compatible Triton image** — keep the V100 and pin an older
  `custom-triton` build (TensorRT 8.6 was the last to support Volta, or a build
  using the CUDA/ONNX-Runtime EP instead of the TensorRT EP). The tag is
  currently **hardcoded** in `fortiaigate/templates/triton-server.yaml`; this
  would need the tag made configurable **and** a compatible image published to
  the ACR. Owned on the FortiAIGate image-build side, not in this repo.
- **Disable GPU/Triton** — set `gpu_enabled = false` for a clean deploy. Note
  the scanners are thick-client/thin-server against Triton, so inference does
  not function in this mode — it is an unblock, not a finished deployment.
