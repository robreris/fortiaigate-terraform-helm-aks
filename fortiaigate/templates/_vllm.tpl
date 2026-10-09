{{- /*
The policyGuard vLLM serving container, its model loader and its volumes,
defined ONCE and rendered into one of two pods (vllm.gpuAttach, resolved by
fortiaigate.vllmGpuPlan):

  shared         (co-located) inside the Triton pod, Deployment triton-vllm-server
                 (templates/triton-server.yaml):
                 no GPU request; NVIDIA_VISIBLE_DEVICES comes from the pod
                 annotation the gpu-probe initContainer wrote, so the NVIDIA
                 container runtime attaches the card the kubelet gave Triton.
                 Both Services publish not-ready addresses in this mode,
                 since pod readiness spans both engines (see the container's
                 READINESS note).
  dedicated      the standalone vllm-server Deployment
                 (templates/vllm-server.yaml): requests vllm.gpuCount whole
                 cards of its own, readiness probe as any pod.

Everything that must agree between the two call sites and guardrail.yaml is a
named template here: the image pin, the HTTP port, the reporter port, the
label the vLLM Services select on, the annotation key.

PORTS. vLLM upstream serves on 8000 and the reporter on 9109, and so does
Triton (HTTP 8000, gRPC 8001, metrics 8002, reporter 9109). In the
co-located pod the two share one network namespace, so vLLM moves to 8100
and its reporter to 9110 — and it does so in BOTH modes, because the vLLM
Services are headless: a headless Service does no port translation, the
client resolves the name to pod IPs and dials the port it was given, so
"port 8000 -> targetPort 8100" would not work and the port on the wire has
to be the same wherever the container runs. guardrail.yaml renders
POLICYGUARD_VLLM_URL and the metering endpoint from the two helpers below;
the loader reads --port for its own health check; the reporter reads
AIGATE_REPORTER_PORT.
*/ -}}

{{/*
The serving container and shared-mode GPU probe use one engine tag.
Defaults match the release bundle; override only with a qualified image set.
*/}}
{{- define "fortiaigate.vllmImage" -}}
{{ .Values.fortiaigate.image.repository }}/vllm-server:{{ .Values.vllm.image.tag }}
{{- end }}

{{/*
The faig-models carrier, one image for both engines (the policyGuard HF
directory for vLLM and the PII ONNX for Triton, every file encrypted). This
is the chart's ONE pin: triton-server.yaml's model-loader and
fortiaigate.vllmModelLoader below both render it. Keep its tag aligned with the inference images when importing a release.
*/}}
{{- define "fortiaigate.modelsImage" -}}
{{ .Values.fortiaigate.image.repository }}/faig-models:{{ .Values.triton.image.modelsTag }}
{{- end }}

{{/* vLLM's OpenAI-compatible HTTP port (--port, Service vllm-server). */}}
{{- define "fortiaigate.vllmHTTPPort" -}}
8100
{{- end }}

{{/* vLLM's GPU licence reporter port (AIGATE_REPORTER_PORT, Service vllm-server-metering). */}}
{{- define "fortiaigate.vllmReporterPort" -}}
9110
{{- end }}

{{/*
The label the two vLLM Services select on. A pod has ONE app label and the
co-located pod's is triton-vllm-server (fortiaigate.tritonName), so the
Services use a second key, carried by the co-located triton-vllm-server pods
AND the standalone vllm-server pods — one pair of Services serves both modes.
*/}}
{{- define "fortiaigate.policyGuardLabelKey" -}}
fortiaigate.io/policyguard
{{- end }}

{{/*
The Triton pods' identity in the mode in force — the Deployment's name, the
prefix of its pods' names AND the value of their `app` label, one string:
triton-vllm-server in shared mode (co-located: the pod carries BOTH engines) and
triton-server otherwise. Everything that selects the pods follows it in the
same render: the Deployment's selector, the two Triton Services
(triton-server, triton-server-metering), the standalone vllm-server pod's
anti-affinity, NOTES.txt's commands; gpu_expose_tool.sh resolves it from the
cluster, or selects `app in (triton-server,triton-vllm-server)`, which
matches either mode. What does NOT move: the Service NAMES, which are
addresses — the DLP scanner dials triton-server:8001 and the metering scrape
triton-server-metering:9109 — and the second label key the vLLM Services
select on (fortiaigate.policyGuardLabelKey). The shared-mode-only objects
(ServiceAccount, Role, RoleBinding, the gpu-probe ConfigMap) take the same
name. A change of mode on upgrade is therefore a delete of one Deployment
and a create of the other, with the Services' selectors switching at the
same time: Helm creates before it deletes, so the new pod waits Pending on
the card until the old one is gone, and the old pods leave the Services when
the upgrade starts rather than when they terminate — a Recreate rollout's
outage, a few seconds earlier (accepted 2026-10-04).
*/}}
{{- define "fortiaigate.tritonName" -}}
{{- $colocated := false -}}
{{- if include "fortiaigate.vllmEnabled" . -}}
{{- $plan := include "fortiaigate.vllmGpuPlan" . | fromJson -}}
{{- $colocated = eq $plan.mode "shared" -}}
{{- end -}}
{{- if $colocated -}}triton-vllm-server{{- else -}}triton-server{{- end -}}
{{- end }}

{{/*
The pod annotation the gpu-probe initContainer writes (the UUIDs of the card(s)
the kubelet gave the pod) and the vllm container reads through the downward
API as NVIDIA_VISIBLE_DEVICES.
*/}}
{{- define "fortiaigate.gpuDeviceAnnotation" -}}
fortiaigate.io/gpu-device
{{- end }}

{{/* files/gpu-probe.py, hashed into the co-located Triton pod template and shipped in a ConfigMap. */}}
{{- define "fortiaigate.gpuProbeScript" -}}
{{ .Files.Get "files/gpu-probe.py" }}
{{- end }}

{{/*
--tensor-parallel-size for vLLM. Args: root, colocated (true in shared mode).
  shared         Triton's gpuCount: the probe records EVERY card of the pod's
                 allocation and the vllm container attaches them all, so a
                 Triton pod holding two cards gets a vLLM sharded across both
                 — exactly what a two-card vllm-server does in dedicated
                 mode. vllm.resources.limits.gpuCount does not apply.
  dedicated      vllm.resources.limits.gpuCount, the cards it requests.
More than 1 needs identical cards and a memory-backed /dev/shm
(fortiaigate.vllmVolumes switches it); tensor x data parallel through
vllm.extraArgs must not exceed the card count.
*/}}
{{- define "fortiaigate.vllmTensorParallel" -}}
{{- if .colocated -}}
{{- int (dig "resources" "limits" "gpuCount" 1 (.root.Values.triton | default dict)) -}}
{{- else -}}
{{- int (dig "resources" "limits" "gpuCount" 1 (.root.Values.vllm | default dict)) -}}
{{- end -}}
{{- end }}

{{/*
The initContainer that delivers the policyGuard model. It runs the faig-models
carrier image and copies the /models/policyguard subtree — CIPHERTEXT, every
file encrypted under the same cipher as the PII ONNX
(docs/workflows/model-encryption.md) — into the vllm-models emptyDir the
serving container mounts read-only. `/.` not `/*`: the HF directory's
contents (dotfiles included) land at the volume ROOT, so the path handed to
the serving container is always /opt/faig/models whatever the model is
called; the client-facing name comes from --served-model-name. Decryption is
the serving container's own (fortiaigate.vllmContainer). Args: root.
*/}}
{{- define "fortiaigate.vllmModelLoader" -}}
- name: vllm-model-loader
  image: {{ include "fortiaigate.modelsImage" . }}
  imagePullPolicy: {{ .Values.fortiaigate.image.pullPolicy }}
  command: ['sh', '-c', 'cp -r /models/policyguard/. /vllm-models/ && echo "policyGuard model copied successfully"']
  volumeMounts:
  - name: vllm-models
    mountPath: /vllm-models
{{- end }}

{{/*
The vllm serving container. Args: root, colocated (bool: true in shared mode,
where the container rides in the Triton pod).

The image's ENTRYPOINT is the decrypting loader, faig-vllm-loader
(modules/vllm/loader), the vLLM counterpart of Triton's repository agent. It
unwraps so_secret from the envelope sealed into it at image build (bound to
that image's vLLM installation), decrypts every model file into sealed memfds,
runs `vllm serve` on a directory of links to them — no plaintext on any named
inode — supervises it, and releases the memory at vLLM's first healthy answer.
So the model is held in RAM ONCE, during the load window: the container's
memory limit must cover the model's size plus vLLM's own footprint
(values.yaml, vllm.resources). A carrier whose policyguard subtree is
plaintext is REFUSED (FAIG_ALLOW_PLAINTEXT_MODEL=1 overrides, for a stand-in
in a lab). The args: below are appended to `vllm serve` verbatim, beginning
with the model path exactly as upstream's ["vllm","serve"] took it — ARGS
ONLY, NEVER command:, which would skip the decryption AND the reporter's
launch path. THE GPU REPORTER NEEDS NO COMMAND: the image drops a .pth into
site-packages, so runtime_bootstrap starts the compiled runtime-agent with the
interpreter; its atomic listen on AIGATE_REPORTER_PORT elects one instance
across competing launchers. The image must carry both; if they are absent the
endpoint never answers and the licence manager records this engine as an
unreadable source — visible, never mistaken for "no cards".

--gpu-memory-utilization is EXPLICIT by design: the 0.9 upstream default
assumes it owns the GPU, and ours may share with Triton. values.yaml sizes it
for the pinned model, or leaves it to the mode (0.85 on a card of its own,
0.80 beside Triton; fortiaigate.vllmGpuMemoryUtilization).

--max-model-len is the per-request ceiling: vLLM answers 400 for any
prompt+answer over it, which the scanner turns into a failed detector and the
gateway into a 503. It ALSO divides the KV pool into a worst-case concurrency
figure (pool / max-model-len) — but it does NOT size that pool, which comes
from gpu-memory-utilization alone. Raising it costs no extra memory; it only
lowers the concurrency vLLM can guarantee if every request were full length.
UNSET (vllm.maxModelLen empty or 0) omits the flag and vLLM falls back to the
checkpoint's own max_position_embeddings; vLLM REFUSES TO START when the KV
pool cannot hold one sequence of that length, so on a GPU that cannot afford
the whole context this must stay set.

First boot pays model load + torch.compile / CUDA-graph capture before
/health answers (the compile-cache volume only helps from the second boot
on): the startupProbe suspends liveness for up to 30 min (120 x 15 s), the
same window triton-server.yaml gives its TensorRT build.

READINESS. The probe is the engine's own /health in both modes (never the
reporter's /ready: an image without the reporter would then have NO
INFERENCE AT ALL, a total outage caused by licensing; metering degrades,
inference does not). Co-located, the probe does NOT decide whether anything
reaches either engine, and could not: a Service publishes a pod only when
EVERY container is Ready, and the kubelet marks a container not Ready while
it is not running AND while its startupProbe has not passed, readiness probe
or not (prober_manager.go UpdatePodStatus: "no readinessProbe -> always
ready" applies only to a started container). So this container drags pod
readiness down at every pod start (minutes of model load), every restart and
every crash loop whatever its probes say. The separation lives in the
SERVICES instead: in shared mode both triton-server and vllm-server
publish not-ready addresses (triton-server.yaml, vllm-server.yaml), so each
engine's availability is its own — a refusing Triton is skipped by the DLP
client's round_robin, a loading vLLM refuses connections (the loader binds
nothing while decrypting, vLLM listens only once its engine is built) and
the policy-guard judge's dialer moves to the next pod; with one pod, POLICY
503 until the model is up, today's behaviour. The readiness probe stays so
that `kubectl get pods` READY (1/2 against 2/2) and the pod's Ready
condition — what `kubectl rollout status` waits for — mean "both engines
are up".

Co-located only, the postStart guard: NVIDIA_VISIBLE_DEVICES is resolved from
the pod annotation when the container is CREATED. The probe settles so the
patch has reached the kubelet by then (lab: 0 s raced, 2 s and 5 s never
did), but if it ever resolves to "" the runtime injects no card and vLLM
would die minutes later, after decrypting the whole model, on "Failed to
infer device type". The guard sees the empty value at once; a failed
postStart hook kills the container, the kubelet restarts it with backoff and
resolves the env again from the pod it now has (a restarted container
re-read a changed annotation 9 of 9 times on the lab), and the reason is in
the pod's events. Inside a container that DID get a card the variable reads
`void` (the runtime consumes it when it injects), which is non-empty, so the
guard is silent in the normal case.
*/}}
{{- define "fortiaigate.vllmContainer" -}}
{{- $root := .root -}}
{{- $colocated := .colocated -}}
{{- $tp := int (include "fortiaigate.vllmTensorParallel" .) -}}
{{- $port := include "fortiaigate.vllmHTTPPort" $root -}}
{{- $meter := include "fortiaigate.vllmReporterPort" $root -}}
- name: vllm
  image: {{ include "fortiaigate.vllmImage" $root }}
  imagePullPolicy: {{ $root.Values.fortiaigate.image.pullPolicy }}
  # The last lines of the log become the termination message, so a crash
  # loop's reason ("Failed to infer device type", a sealed-secret refusal)
  # shows in `kubectl describe pod` without pulling the log.
  terminationMessagePolicy: FallbackToLogsOnError
  args:
    - /opt/faig/models
    - --port={{ $port }}
    - --served-model-name={{ include "fortiaigate.policyGuardModelName" $root }}
    - --gpu-memory-utilization={{ include "fortiaigate.vllmGpuMemoryUtilization" $root }}
    {{- if gt $tp 1 }}
    - --tensor-parallel-size={{ $tp }}
    {{- end }}
    {{- with ($root.Values.vllm).maxModelLen }}
    - --max-model-len={{ . }}
    {{- end }}
    {{- /* vllm.logVerbose (values.yaml), Triton's --log-verbose for vLLM.
           0 silences the HTTP access log — one line per request AND per
           /health probe — so the log holds start-up, warnings, errors and
           the engine's stats line under load, as Triton's does at 0.
           1 logs every request the way Triton's 1 does: the access line,
           "Received request <id>: params: SamplingParams(...)" and
           "Generated response <id>: output: '...', finish_reason: ..." —
           the judge's verdict text. The PROMPT is not among them: this
           vLLM logs it only at its DEBUG logger level, which the chart
           never sets. Never --disable-log-stats here: in this vLLM it also
           switches off the per-request Prometheus metrics (cli_args.py
           says so). */}}
    {{- if le (int (($root.Values.vllm).logVerbose)) 0 }}
    - --disable-uvicorn-access-log
    {{- else }}
    - --enable-log-requests
    - --enable-log-outputs
    {{- end }}
    # No --language-model-only: the pinned checkpoint is text-only and
    # declares no modalities, so vLLM's image/audio request paths are
    # already unreachable. A multimodal checkpoint would need it back,
    # alongside the per-prompt modality limits in vllm.extraArgs.
    {{- range $root.Values.vllm.extraArgs }}
    - {{ . | quote }}
    {{- end }}
  env:
  # WHICH MACHINE this engine's cards are in, from the pod's own downward
  # API. Diagnostics an operator can act on, never identity: the licence
  # dedups on card uuid alone, and an engine that was never told its node
  # still reports cards that still count.
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: spec.nodeName
  - name: POD_NAME
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.name
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.namespace
  - name: AIGATE_PRODUCT
    value: "vllm"
  # The reporter's own port (header: PORTS). Co-located, Triton's reporter
  # holds 9109 in the same network namespace; with one port the two would
  # fight the listen election and only one engine would report. Two
  # reporters, two records with the same card uuid, deduplicated to one card.
  - name: AIGATE_REPORTER_PORT
    value: {{ $meter | quote }}
  # The reporter's /ready asks the ENGINE whether it is serving. It checks
  # LOCAL facts only and never reaches the licence manager — an LM outage
  # turning every engine pod NotReady would be a total outage caused by
  # licensing.
  - name: AIGATE_ENGINE_HEALTH
    value: "http://127.0.0.1:{{ $port }}/health"
  {{- if $colocated }}
  # shared (co-located): with no nvidia.com/gpu request the device plugin sets nothing,
  # so the NVIDIA container runtime is told the card here — the one the
  # gpu-probe initContainer recorded on this pod a moment ago, which is the
  # one the kubelet then handed Triton. Inside the container it is CUDA
  # device 0, same as in Triton. In dedicated mode the plugin injects
  # these two at container creation, so they are absent from the spec there.
  - name: NVIDIA_VISIBLE_DEVICES
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.annotations['{{ include "fortiaigate.gpuDeviceAnnotation" $root }}']
  - name: NVIDIA_DRIVER_CAPABILITIES
    value: compute,utility
  lifecycle:
    postStart:
      exec:
        command:
          - /bin/sh
          - -c
          - >-
            [ -n "$NVIDIA_VISIBLE_DEVICES" ] ||
            { echo "gpu-probe annotation {{ include "fortiaigate.gpuDeviceAnnotation" $root }} was empty when this container was created, so no GPU was attached; exiting so the kubelet re-reads it on restart" >&2; exit 1; }
  {{- end }}
  ports:
  - containerPort: {{ $port }}
    name: policyguard
    protocol: TCP
  - containerPort: {{ $meter }}
    name: vllm-meter
    protocol: TCP
  resources:
    {{- $res := $root.Values.vllm.resources }}
    limits:
      {{- range $k, $v := $res.limits }}
        {{- if or (eq $k "cpu") (eq $k "memory") }}
      {{ $k }}: {{ $v }}
        {{- else if and (eq $k "gpuCount") (not $colocated) ($root.Values.fortiaigate.gpu.enabled) }}
      {{ $res.limits.gpuResourceName }}: {{ $v }}
        {{- end }}
      {{- end }}
    requests:
      {{- range $k, $v := $res.requests }}
      {{ $k }}: {{ $v }}
      {{- end }}
  volumeMounts:
  - name: vllm-models
    mountPath: /opt/faig/models
    readOnly: true
  - name: vllm-compile-cache
    mountPath: /opt/faig/cache
  - name: vllm-shm
    mountPath: /dev/shm
  startupProbe:
    httpGet:
      path: /health
      port: {{ $port }}
    periodSeconds: 15
    timeoutSeconds: 5
    failureThreshold: 120
  livenessProbe:
    httpGet:
      path: /health
      port: {{ $port }}
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 15
  readinessProbe:
    httpGet:
      path: /health
      port: {{ $port }}
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 15
{{- end }}

{{/*
vLLM's three volumes. Args: root, tp (the tensor-parallel size, for /dev/shm).
Named vllm-* so they can sit beside Triton's own model-repository and
shm-memory in the co-located pod. /dev/shm: PyTorch worker IPC wants more
than the 64MB container default. Disk-backed on purpose (unlike Triton's
Memory-backed shm): model bytes already cost RAM once; don't pay page-cache
prices twice. Tensor parallel is the exception: NCCL and the per-card workers
talk through /dev/shm constantly, so it goes memory-backed.
VLLM_CACHE_ROOT=/opt/faig/cache is baked into the image; the compile-cache
volume backs it — without it every pod restart repays the torch.compile
warmup.
*/}}
{{- define "fortiaigate.vllmVolumes" -}}
- name: vllm-models
  emptyDir:
    sizeLimit: {{ .root.Values.vllm.modelVolumeSizeLimit }}
- name: vllm-compile-cache
  emptyDir:
    sizeLimit: {{ .root.Values.vllm.cacheVolumeSizeLimit }}
- name: vllm-shm
  emptyDir:
    {{- if gt (int .tp) 1 }}
    medium: Memory
    {{- end }}
    sizeLimit: 4Gi
{{- end }}
