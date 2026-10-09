# GPU compatibility for Triton and vLLM (Azure)

Build0047 runs the DLP model in Triton and the policy model in vLLM. Image
manifests are `linux/amd64`; offline rendering does not establish GPU/runtime
compatibility. See [the compatibility audit](build0047-compatibility.md#gpu-and-cpu-capability-boundaries).

## AKS profiles

| Terraform setting | Layout | Capacity requirement |
| --- | --- | --- |
| `gpu_enabled=true`, `vllm_gpu_attach="shared"` | One combined `triton-vllm-server` pod | One GPU with sufficient VRAM; NVIDIA runtime must expose Triton's allocation to vLLM |
| `gpu_enabled=true`, `vllm_gpu_attach="dedicated"` | Separate Triton/vLLM pods | Separate GPU allocations; typically `gpu_node_count=2` with one-GPU VMs |
| `gpu_enabled=false` | CPU Triton, no vLLM | POLICY detectors fail closed without vLLM; CPU capability is unqualified |

Terraform defaults to an A10 VM (`Standard_NV36ads_A10_v5`) and explicit shared
mode. This SKU worked for earlier Triton deployments; combined build0047
Triton/vLLM memory, model loading, and runtime injection still need a live AKS
test. It is a starting configuration, not a qualified recommendation for the
new release. Shared pod container memory limits total 49 GiB (25 GiB Triton +
24 GiB vLLM); host memory and VRAM are different budgets. Chart comments describe
approximately 16.6 GiB of vLLM GPU use before KV cache and about 3 GiB per Triton
DLP instance. Increasing model context or instance counts can exhaust VRAM.

## Before deploying

Verify region/SKU availability and GPU quota in your subscription using the
[permissions preflight](permissions-preflight.md). Earlier deployment notes
identified A10/A100 as supported hardware and TensorRT 10 requiring SM 75+;
confirm release-specific hardware support before choosing a different GPU.
Do not reuse the earlier V100 configuration without compatibility testing.

Provision the GPU pool during the README infrastructure bootstrap. Terraform
keeps `gpu_driver="Install"` explicit, installs the NVIDIA device plugin, and
sets the GPU pool's `fortiaigate-gpu=true:NoSchedule` taint. Inference pods
select `fortiaigate-role=gpu` and tolerate this taint. Choose sufficient
`gpu_node_count` for dedicated mode and any replica/GPU-count overrides.

Use `update_strategy="Recreate"` when capacity has no spare cards for surge
pods. This introduces downtime but avoids a GPU-constrained rolling update
stall. Node-pool resizing/replacement also needs a planned interruption;
build0047 deployment licensing does not require a new hostname license.

## Live qualification

Verify both engines become ready, model decryption/loading succeeds, the GPU
probe can patch its pod, both engines see the intended device, license coverage
reflects actual GPU allocations, and DLP/POLICY requests complete. Exercise
restart, certificate replacement, concurrent scans, and memory pressure. Record
results and hardware in [the deployment checklist](testing.md). Shared and
dedicated profiles must be tested separately; changing topology is an upgrade.
