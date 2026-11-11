# Stage FortiAIGate 8.0.3 build 6207 in Azure Container Registry

Fortinet ships 18 prebuilt Docker image archives. The [build 6207 inventory](build6207-images.json) records their exact tags and image config digests, plus the SHA-256 of the separate vendor Helm archive. The upload script mirrors the full set, including images for optional features.

| Image | Tag |
|-------|-----|
| `action-guard`, `api`, `auth`, `fabric`, `guardrail`, `guardrail-scanner`, `inference-hooks`, `license_manager`, `llm-gateway`, `logd`, `mcp-gateway`, `observability`, `plugin-adapter`, `plugin-adapter-mcp`, `webui` | `V8.0.3-build6207` |
| `custom-triton` | `25.11-onnx-trt-agt-rpt-s1` |
| `faig-models` | `0.0.5-s1` |
| `vllm-server` | `0.28.0-1-rpt-s1` |

## Prepare ACR

Run the script with Bash, Azure CLI, a running Docker daemon with Buildx, and `jq`. The archives total about 43 GiB. Allow additional space in Docker's storage for loaded layers.

Sign in with `az login` and select the registry's subscription with `az account set --subscription "<acr-subscription>"`. Your publishing identity needs permission to read the registry resource and read and push images. Use `AcrPush` in Registry RBAC mode, or `Container Registry Repository Writer` in RBAC + ABAC mode with access to the `fortiaigate-v803` repositories. [Microsoft ACR authentication](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication) and [push troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-container-registry/troubleshoot-push-error-operation-disallowed-timeout).

Reuse an existing private ACR or create one in a [separate resource group](registry-and-images.md#where-the-registry-lives). Choose a globally unique registry name.

```bash
ACR_NAME="yourregistry"
ACR_RG="fortiaigate-acr"
az group create --name "$ACR_RG" --location "eastus"
az acr create --resource-group "$ACR_RG" --name "$ACR_NAME" --sku Standard --admin-enabled false
```

## Load, push, and verify

From the repository root, set `BUILD_DIR` to the directory holding the Fortinet archives and `ACR_NAME` to the registry resource name.

```bash
BUILD_DIR="/path/to/build6207" ACR_NAME="yourregistry" bash scripts/push-build6207-to-acr.sh
```

The [script](../scripts/push-build6207-to-acr.sh) resolves the login server with Azure CLI and pushes to `fortiaigate-v803/<image>`. It verifies the config digest in ACR after each push. A rerun skips matching images and stops on a tag conflict. Rerun after an interrupted upload to refresh authentication and resume. [Docker manifest inspection](https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/).

## AKS pull access and tfvars

For Registry RBAC mode, set `acr_id` to manage the AKS kubelet's `AcrPull` grant in Terraform, or use the [manual grant procedure](registry-and-images.md#later-grant-acrpull-once-the-cluster-exists). For RBAC + ABAC mode, manage the kubelet's `Container Registry Repository Reader` role separately and leave `acr_id` empty. Scope the grant to the build 6207 repositories if you use repository conditions. [Microsoft AKS and ACR integration](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration).

Use these image settings after the AKS chart port is ready.

```hcl
image_repository        = "yourregistry.azurecr.io/fortiaigate-v803"
image_tag               = "V8.0.3-build6207"
triton_image_tag        = "25.11-onnx-trt-agt-rpt-s1"
triton_models_image_tag = "0.0.5-s1"
vllm_image_tag          = "0.28.0-1-rpt-s1"
```

Use the login server printed by the script. The [additional database and infrastructure images](registry-and-images.md#what-this-stack-does-and-doesnt-consume-from-the-registry) are supplied through their own charts and registries.
