# FortiAIGate 8.0.2 build0047 compatibility audit

This document compares the pre-port AKS deployment with the supplied build0047
release and defines the work needed for a fresh AKS installation. It is an
implementation plan, not a declaration that build0047 is supported. The working
branch ports the chart and Terraform defaults to build0047; offline validation
passes and live AKS qualification remains outstanding.

## Sources and evidence

Inspected on 2026-10-09 against repository commit `ff3a1fe` on branch `v8.0.2`:

- Release directory: `../FortiAIGate-on-EKS/v802-builds/build0047`.
- Chart archive: `FAIG_helm_chart-V8.0.2-build0047-FORTINET.tar.gz`.
- Chart archive SHA-256: `e92975c31b2f223093f4f8fe3214e44a5c30b3fdfeba94dfcf20ad3b3235002c`.
- Incoming chart version and appVersion: `8.0.2`.
- Docker `manifest.json` and referenced image configurations in all ten image
  archives. All ten report `linux/amd64`. Image layers were not executed or
  scanned; archive filenames alone were not used to determine tags.
- Offline Helm renders of the incoming chart in CPU, shared GPU, and dedicated
  GPU modes, with an example registry/tag and AGIC ingress class/hostname.
  All three rendered and parsed as YAML successfully, using the archive's
  vendored subcharts. These were renders of the incoming chart, not our AKS port.

No images were loaded or pushed, no cluster was contacted, and no deployment
configuration was changed during this audit. Application behavior described
only in chart comments is marked as such below. No application migration or
runtime compatibility has been established.

## Deployment compatibility map

| Area | Current AKS deployment | Incoming build0047 | Work required |
| --- | --- | --- | --- |
| Application services | Core plus eight scanner deployments | LLM gateway, guardrail dispatcher, DLP scanner, and policy guard; core/scanners templates removed | Replace obsolete service configuration and tests; retain API, webui, and logd with their new configuration |
| Licensing | Node-name/license-file map, ConfigMap, hostname affinity; license-manager DaemonSet | Chart values describe deployment license upload through `POST /api/v1/admin/licenses`; license-manager Deployment with two replicas | Remove obsolete license-file wiring and GPU-license precondition for the new release; document API onboarding and verify capacity/coverage behavior live |
| Placement | Licensed-hostname affinity and AKS GPU selector/tolerations | Rendered application and inference pods have no node selectors/tolerations | Preserve explicit app/GPU pool placement while retiring the node-license restriction; apply GPU placement to both combined and standalone inference pods |
| Ingress | `/api/` to API, `/ui` to webui, `/` to core | `/api/` to API, `/ui` and `/` to webui, `/ai` to LLM gateway | Update routes, readiness probes, UI proxy, and endpoint documentation; verify `/ai` prefix handling without global path rewrites |
| Web TLS | Terraform-generated or supplied certificate, or cert-manager; external-secret support and rollouts | Chart creates `fortiaigate-tls-secret` from bundled files; application templates hardcode its name | Port existing-secret helpers/checksums and Reloader annotations; avoid competing ownership or importing bundled private keys into the repo |
| Internal TLS | Separate Terraform-owned CA/Secret for internal services and database clients | Shared TLS secret and existing database client paths; no equivalent internal-secret settings | Port separate mounts, CA trust, and independent rollouts to the new service set; inspect each service's supported trust configuration |
| Storage | Azure Files shared RWX PVC; separate PostgreSQL/Redis Azure Disk PVCs | Databases still default to the shared RWX claim | Preserve Terraform database storage overrides and claim identities |
| PostgreSQL credentials | Stable Terraform-owned passwords and Secret | Application references the release PostgreSQL Secret | Preserve credential resource addresses, Secret keys, and `postgresql.auth.existingSecret` |
| Credential encryption | No corresponding master-key template | Shared master-key Secret generated with lookup and `keep`, or supplied existing Secret | Decide and test stable ownership; preserve key across apply, upgrade, reinstall, and restore before storing real credentials |
| CSRF | Random chart-generated Secret unless explicitly configured | Still generates a new value on every offline render | Resolve stable secret handling or retain this as an explicit production gap; do not assume the new chart fixes it |
| Database dependencies | PostgreSQL chart 16.7.0 and Redis chart 22.0.0 | Same versions and identical Chart.lock | Retain locked dependencies; identical locks do not prove schema migration compatibility |
| Optional DP agent | Absent | Disabled by default; references `dp_agent:V8.0.2-build0047` | Keep disabled for the first milestone; obtain the missing image before enabling |

The incoming `values.yaml` contains some stale comments referring to node
licenses and a license-manager DaemonSet. The rendered objects and active
template logic take precedence over those descriptions.

## Image compatibility

The archive manifests match all ten FortiAIGate image repositories/tags used by
the default shared/dedicated GPU renders. Retag the source registry prefix to
the target ACR prefix while retaining these repository names and tags:

| Repository | Verified manifest tag | Role |
| --- | --- | --- |
| `api` | `V8.0.2-build0047` | Management API |
| `webui` | `V8.0.2-build0047` | Web UI |
| `llm-gateway` | `V8.0.2-build0047` | LLM traffic gateway |
| `guardrail` | `V8.0.2-build0047` | Guardrail dispatcher |
| `guardrail-scanner` | `V8.0.2-build0047` | DLP and policy-guard binaries selected by container command |
| `license_manager` | `V8.0.2-build0047` | Deployment licensing |
| `logd` | `V8.0.2-build0047` | Logging |
| `custom-triton` | `25.11-onnx-trt-agt-rpt-s1` | Triton and GPU metering |
| `vllm-server` | `0.28.0-rpt-s1` | Policy model serving and GPU probe |
| `faig-models` | `0.0.4-s1` | Combined encrypted model carrier |

Inference/model tags are pinned in `triton-server.yaml` and `_vllm.tpl` in the
incoming chart. The current Terraform `triton_image_tag` and
`triton_models_image_tag` overrides will not automatically change those pins.
Update their contract explicitly; do not retain variables that silently do
nothing. There is no `core` or old `scanner` image in this bundle, and
`faig-models` replaces `triton-models`.

The chart still needs external images not supplied in the release archives:

- `docker.io/bitnamilegacy/postgresql:17.4.0-debian-12-r19`
- `docker.io/bitnamilegacy/redis:8.2.0-debian-12-r0`
- `docker.io/bitnamilegacy/os-shell:12-debian-12-r50`

Registry availability, pull access, image security, and actual GPU execution
remain unverified. See [registry setup](registry-and-images.md) for the port's
build0047 image instructions.

## Ports, probes, and certificate names

| Service/engine | Rendered endpoint | Readiness in the incoming chart | AKS action |
| --- | --- | --- | --- |
| API | 8000 | None | Restore an HTTPS readiness probe; validate the current `/openapi.json` endpoint against the new binary |
| Webui | 3000 | None | Restore an HTTPS `/ui` readiness probe and validate root behavior |
| LLM gateway | 8080 | HTTPS `/fortiaigate/health/readiness` | Preserve probe and validate it before/after license onboarding |
| Guardrail, DLP scanner, policy guard | gRPC 50051; health 50052 | gRPC health on 50052 | Use internal TLS material; verify client trust and health endpoint behavior live |
| License-manager | HTTPS 9443 | `/readyz`, with `/healthz` liveness | Preserve probes and investigate database/internal-service trust configuration |
| Triton | HTTP 8000, gRPC 8001, metrics 8002, metering 9109 | HTTP `/v2/health/ready` | Preserve internal-only endpoints and GPU placement |
| vLLM | HTTP 8100, metering 9110 | HTTP `/health` | Preserve internal-only endpoints and verify model startup/metering |

Application Gateway renders have no default AGIC annotations unless supplied.
Keep Terraform's HTTPS backend, SSL redirect, private frontend, root trust, and
backend/probe hostname settings. API/webui probes are especially important:
the existing per-backend probing behavior must survive the chart replacement.

Update generated internal certificate SANs in `tls.tf` for the new service
names, including `llm-gateway`, `guardrail`, `dlp-scanner`, and `policy-guard`,
plus optional `dp-agent` if enabled later. Preserve web certificates on externally
exposed backends and generated trust on internal services/datastore clients.
Do not assume every new binary honors the old database CA environment variables;
license-manager now also accesses PostgreSQL and requires specific inspection.

## GPU and CPU capability boundaries

- **Shared GPU:** the rendered Deployment is `triton-vllm-server`, containing
  Triton and vLLM. Triton and a GPU-probe init container each request one GPU;
  vLLM accesses that GPU without its own device-plugin request. Chart comments
  require NVIDIA runtime injection for this arrangement. Verify it on AKS,
  including the probe's Pod-patching RBAC, device visibility, model decryption,
  metering, and simultaneous scans. Rendering does not establish runtime support.
- **Dedicated GPU:** separate `triton-server` and `vllm-server` Deployments each
  request one GPU with defaults. The current one-GPU pool cannot run both
  concurrently; expose or document sufficient capacity and placement.
- **Auto mode:** a node lookup chooses shared/dedicated based on advertised GPU
  capacity. Offline rendering assumes shared. Prefer explicit modes in initial
  validation so a lookup does not change topology between renders and applies.
- **Memory:** shared mode renders container limits of 25 GiB for Triton plus
  24 GiB for vLLM. These are host-memory limits, not VRAM requests. Chart comments
  describe approximately 16.6 GiB of vLLM GPU use before KV cache and about 3 GiB
  per Triton DLP instance. Recalculate node sizing, startup headroom, and GPU
  budgets; the existing A10 choice is not yet qualified for this combined load.
- **CPU mode:** setting `fortiaigate.gpu.enabled=false` still renders
  `triton-server` without a GPU request; it suppresses vLLM. Chart comments say
  POLICY detectors fail closed with gateway 503 without vLLM. Do not advertise
  full CPU-only scanning or remove Triton solely based on the old chart's tests;
  establish actual supported CPU capabilities first.
- **Model coverage:** incoming Triton template comments describe DLP-only model
  serving, with the policy model supplied through vLLM. The old prompt-injection,
  toxicity, language, and code model configuration is absent. Map user-visible
  detectors to the new implementation during functional testing rather than
  assuming one-for-one coverage with the eight old scanners.

## First implementation milestone: fresh installation

1. Port the build0047 application templates/configuration while preserving AKS
   ingress, storage, credentials, TLS, and GPU-driver settings. Keep release
   archives, bundled private keys, and rendered manifests outside Git.
2. Replace node-license Terraform wiring, chart preconditions, and scheduling
   assumptions with deployment-license onboarding. Preserve the two-step
   infrastructure bootstrap because Helm/Kubernetes providers still need AKS
   to exist; remove node discovery as a license prerequisite for the new release.
3. Update chart/image defaults, explicit inference mode/capacity configuration,
   certificate names, and documentation. Adjust `scripts/ui-proxy.mjs` to the
   new gateway and ingress routes. Keep DP agent disabled.
4. Establish stable master-key ownership and test the external-Secret contract
   for all consumers. Describe backup/restore requirements with the database.
5. Update Helm contracts for the new service set, ingress/probes, absence of
   hostname-license affinity, app/GPU placement, independent TLS, and shared
   versus dedicated GPU resources. Retain mocked Terraform checks for all TLS
   modes and invalid combinations; verify actual Terraform value composition.
6. Run formatting, lint, validation, and offline suites in isolation, then test
   a fresh AKS deployment with license onboarding, gateway health, real scan
   requests, model loading, and certificate replacement. Record exact pool/GPU
   sizes and capability limitations in [testing](testing.md).

Fresh-install acceptance requires ready application/database pods, persistent
credentials/master key, valid gateway routing/backend trust, successful license
onboarding, and demonstrated DLP/POLICY requests on the chosen GPU profile.
CPU-only and dedicated-GPU profiles need their own recorded capability results.

## Existing deployment upgrades remain a separate milestone

The [8.0.1-to-8.0.2 upgrade guide](upgrade-8.0.1-to-8.0.2.md) records the
current branch comparison and staged preparation/cutover procedure. It does not
change the qualification status described here.

The supplied chart and image manifests do not establish a supported migration
from build0031. Obtain release migration guidance and qualify database schema
changes, deployment license conversion, credential encryption, retired detector
settings, and gateway endpoint changes before recommending an in-place upgrade.

The same database dependency versions do not imply the same application schema.
Back up databases, shared files, and encryption keys; test restoration in a
fresh deployment. Check Helm's removal of old Deployments/DaemonSets and
Terraform's removal of the license ConfigMap separately from data PVCs and
stable credential resources. A Helm rollback alone must not be assumed to
reverse database migrations. Update [operations](operations.md) and
[AGENTS.md](../AGENTS.md) when the new licensing/placement contract is implemented.

## Implemented AKS port

The working branch ports the build0047 application templates while preserving
Azure Files/Azure Disk storage and stable PostgreSQL credential addresses. It
adds explicit shared/dedicated GPU topology and fixed GPU capacity, restores
app/GPU placement and ingress probes, and configures external web/internal TLS
Secrets plus Go client trust via `SSL_CERT_FILE`. Service-specific runtime trust
behavior still needs live verification.

Terraform owns the shared master key, CSRF key, and Redis password. The chart
retains external-Secret contracts and standalone master-key/CSRF lookup fallbacks.
Node-license ConfigMap/affinity wiring is removed; nonempty legacy license maps
fail validation. The bootstrap remains two-step without node discovery. Inference
image overrides are meaningful and default to the verified release tags; the DP
agent is forced off in Terraform. The audit tables above describe the input
comparison, not outstanding implementation for every row.

This port does not qualify existing data/schema/license migration, shared GPU
runtime behavior, CPU feature coverage, or real image execution. Follow the
[live checklist](testing.md) before using it in a populated environment.

Offline port verification on 2026-10-09: 19 Python tests (Helm contracts and real
certificate checks), 15 mocked Terraform runs, isolated Terraform validation,
TFLint 0.53.0 with Azure ruleset 0.27.0, formatting, local documentation links,
and proxy/GPU-probe syntax checks passed. Existing Azure provider deprecation
warnings remain. Test renders and provider fixtures create no cloud resources.
