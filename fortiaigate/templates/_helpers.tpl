{{/*
Expand the name of the chart.
*/}}
{{- define "fortiaigate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fortiaigate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fortiaigate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fortiaigate.labels" -}}
helm.sh/chart: {{ include "fortiaigate.chart" . }}
{{ include "fortiaigate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fortiaigate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fortiaigate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fortiaigate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fortiaigate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper namespace
*/}}
{{- define "fortiaigate.namespace" -}}
{{- .Release.Namespace }}
{{- end }}

{{/*
Name of the Secret holding the master key that seals credential secrets at
rest (go-common/secret). Every writer and resolver of credential values —
api, dpAgent, llm-gateway — MUST resolve to the SAME name, which is why this
is the one place the fallback chain is written:

  api.masterKeyExistingSecret -> dpAgent.masterKeyExistingSecret -> chart-generated default

The chart-generated default is templates/master-key-secret.yaml, rendered
only when neither override is set. Do not inline this fallback elsewhere —
that is exactly how dpAgent used to end up on a different key than api.
*/}}
{{- define "fortiaigate.masterKeySecretName" -}}
{{- if and .Values.api.masterKeyExistingSecret .Values.dpAgent.masterKeyExistingSecret (ne .Values.api.masterKeyExistingSecret .Values.dpAgent.masterKeyExistingSecret) -}}
{{- fail "api and dpAgent must use the same master-key Secret" -}}
{{- end -}}
{{- .Values.api.masterKeyExistingSecret | default .Values.dpAgent.masterKeyExistingSecret | default (printf "%s-master-key" (include "fortiaigate.fullname" .)) -}}
{{- end }}

{{/*
Renders a JSON map of legacy scanner-name -> maxScanChars for llm-gateway's
scanner-cache key (SCANNER_MAX_SCAN_CHARS_BY_NAME). The named aiguard scanners
are retired; the names remain only for llm-gateway cache-key compatibility and
all resolve to the single guardrail.env.maxScanChars, so changing it invalidates
stale cache entries. (This map can later drop to {} once llm-gateway drops the
per-name cache dimension.)
*/}}
{{- define "fortiaigate.scannerMaxCharsByName" -}}
{{- $globalMax := .Values.guardrail.env.maxScanChars -}}
{{- $result := dict -}}
{{- range $scanner := list "language" "code" "promptinjection" "sensitive" "toxicity" "anonymize" "deanonymize" "customrule" -}}
  {{- $_ := set $result $scanner ($globalMax | toString) -}}
{{- end -}}
{{- $result | toJson -}}
{{- end }}
{{/*
The model name clients call on the vLLM policyGuard server, independent of the
weights directory the pod serves from.

HARDCODED, deliberately not a value: it is an INTERNAL contract between two
templates -- vllm-server.yaml passes it as --served-model-name, and
guardrail.yaml passes the same string to policy-guard as
POLICYGUARD_VLLM_MODEL. A customer who repointed it would break every POLICY
scan (the scanner asks for a model vLLM does not serve, and every scan fails
closed to a 503). Defined ONCE here rather than written literally in both
templates so the two cannot drift apart.
*/}}
{{- define "fortiaigate.policyGuardModelName" -}}
policyguard
{{- end }}

{{/*
Whether the policyGuard vLLM server actually runs in this deployment.

There is deliberately NO vllm.enabled flag. Two things decide it:

  fortiaigate.gpu.enabled   does this deployment have GPUs at all? ("Set to
                            false to run on non-GPU nodes.") A HARD gate — it
                            wins even when vllm.replicas is 1.
  vllm.replicas             the operator's own switch: 0 forces vLLM off on a
                            GPU deployment, 1+ runs it.

Why gpu.enabled has to override rather than merely advise: vLLM has NO CPU
fallback. The image is the upstream CUDA build, whose compiled kernels
(vllm._C / _C_AVX512 / _C_AVX2) are GPU-only, so on a GPU-less node it dies
during ARGUMENT PARSING with "Failed to infer device type" and then
CrashLoopBackOffs forever — no chart value can rescue it. (Triton survives the
same node only because its config.pbtxt is KIND_AUTO and onnxruntime has a CPU
execution provider. vLLM has no equivalent.) Letting a GPU-less deployment ask
for vLLM would guarantee that crash loop, so the flag that says "no GPUs here"
is authoritative.

Both vllm-server.yaml (does the workload exist?) and guardrail.yaml (does
policy-guard address it, or run the clean-returning stub?) resolve through this
one helper, so the workload and the scanner pointed at it cannot disagree.

A missing value reads as OFF: `int` of nil is 0, so a values file that somehow
drops vllm.replicas renders no vLLM rather than silently starting a multi-GB
GPU pod.
*/}}
{{- define "fortiaigate.vllmEnabled" -}}
{{- if and ((.Values.fortiaigate.gpu).enabled) (gt (int ((.Values.vllm).replicas)) 0) -}}
true
{{- end -}}
{{- end }}

{{/*
GPU placement plan for the policyGuard vLLM server, as JSON, so that
triton-server.yaml, vllm-server.yaml, guardrail.yaml and NOTES.txt read the
SAME decision:

  mode         shared | dedicated — vllm.gpuAttach with "auto" resolved.
               shared = vLLM shares Triton's GPU (implemented as co-location:
               a second container in the Triton pod); dedicated = vLLM gets
               GPUs of its own (the standalone vllm-server Deployment)
  requested    vllm.gpuAttach as written (NOTES.txt says "resolved by auto")
  known        the node inventory was readable. True on install/upgrade;
               false when rendered offline (`helm template`, client dry-run)
  total        GPUs allocatable on schedulable nodes, by vLLM's resource name
  nodes        nodes carrying that resource
  tritonCards  cards triton-server takes from the same pool (replicas x gpuCount)
  vllmCards    cards vLLM would need on its own (replicas x gpuCount)
  spare        total - tritonCards
  timeSliced   a node advertises GPU time-slicing (feature-discovery labels)

auto picks dedicated when the spare cards cover vLLM's need and shared
otherwise — so one card is shared (vLLM rides in the Triton pod, then named
triton-vllm-server, on Triton's card), a second card is taken. Offline it
cannot know and picks shared, the single-GPU shape; the next install or
upgrade resolves it for
real. auto never widens the GPU footprint: gpuCount says how many cards vLLM
may take, auto only decides whether it gets them or shares Triton's.
*/}}
{{- define "fortiaigate.vllmGpuPlan" -}}
{{- $vllm := .Values.vllm | default dict -}}
{{- $triton := .Values.triton | default dict -}}
{{- $requested := $vllm.gpuAttach | default "auto" -}}
{{- if not (has $requested (list "auto" "shared" "dedicated")) -}}
{{- fail (printf "vllm.gpuAttach must be \"auto\", \"shared\" (vLLM shares Triton's GPU, inside the Triton pod) or \"dedicated\" (vLLM gets GPUs of its own), got %q. The earlier spellings colocated and shared-runtime are now \"shared\"; device-plugin is \"dedicated\"" $requested) -}}
{{- end -}}
{{- $res := dig "resources" "limits" "gpuResourceName" "nvidia.com/gpu" $vllm -}}
{{- $tritonRes := dig "resources" "limits" "gpuResourceName" "nvidia.com/gpu" $triton -}}
{{- $vllmCards := mul (int ($vllm.replicas | default 0)) (int (dig "resources" "limits" "gpuCount" 1 $vllm)) -}}
{{- $tritonCards := 0 -}}
{{- if eq $tritonRes $res -}}
{{- $tritonCards = mul (int ($triton.replicas | default 0)) (int (dig "resources" "limits" "gpuCount" 1 $triton)) -}}
{{- end -}}
{{- $known := false -}}
{{- $total := 0 -}}
{{- $nodes := 0 -}}
{{- $timeSliced := false -}}
{{- $list := lookup "v1" "Node" "" "" -}}
{{- if $list -}}
{{- range $list.items -}}
{{- $known = true -}}
{{- if not ((.spec | default dict).unschedulable) -}}
{{- $alloc := (.status | default dict).allocatable | default dict -}}
{{- $n := int (index $alloc $res | default 0) -}}
{{- if gt $n 0 -}}
{{- $total = add $total $n -}}
{{- $nodes = add1 $nodes -}}
{{- end -}}
{{- $labels := (.metadata | default dict).labels | default dict -}}
{{- if or (gt (int (index $labels "nvidia.com/gpu.replicas" | default 0)) 1) (eq (index $labels "nvidia.com/gpu.sharing-strategy" | default "") "time-slicing") -}}
{{- $timeSliced = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $spare := sub $total $tritonCards -}}
{{- $mode := $requested -}}
{{- if eq $requested "auto" -}}
{{- if and $known (gt $vllmCards 0) (ge $spare $vllmCards) -}}
{{- $mode = "dedicated" -}}
{{- else -}}
{{- $mode = "shared" -}}
{{- end -}}
{{- end -}}
{{- dict "mode" $mode "requested" $requested "known" $known "total" $total "nodes" $nodes "tritonCards" $tritonCards "vllmCards" $vllmCards "spare" $spare "timeSliced" $timeSliced "resource" $res | toJson -}}
{{- end }}

{{/*
The --gpu-memory-utilization vLLM is started with. An explicit
vllm.gpuMemoryUtilization wins; empty lets the mode decide: 0.85 on a card of
its own (dedicated, not time-sliced), 0.80 when the card is shared with
Triton (shared). NOTES.txt prints the resolved figure.
*/}}
{{- define "fortiaigate.vllmGpuMemoryUtilization" -}}
{{- $set := (.Values.vllm).gpuMemoryUtilization -}}
{{- if $set -}}
{{- $set -}}
{{- else -}}
{{- $plan := include "fortiaigate.vllmGpuPlan" . | fromJson -}}
{{- if and (eq $plan.mode "dedicated") (not $plan.timeSliced) -}}
0.85
{{- else -}}
0.80
{{- end -}}
{{- end -}}
{{- end }}


{{/*
Failure-policy env pins (fortiaigate.failurePolicy.*, #91). Emitted into BOTH
the llm-gateway and the api containers: the gateway applies the policy on every
request, api's manual Check Health sends failThreshold attempts and its
runtime-defaults surface reports the pinned values — so the two pods must read
the SAME env, and one helper is how they cannot drift.

A knob is rendered ONLY when it is set. Empty string, a whitespace-only string
and null all mean "not pinned: the org's Runtime Defaults document governs". A
literal 0 (a legal retryTimes = one attempt) MUST render, which rules out
`with`/`if` on the value (both treat 0 as false). Trimmed, because a
`retryTimes: " "` would otherwise render a FAIG_FAILURE_POLICY_* variable the
process then reads as blank — an operator sees the pin in the pod env while the
org document governs, which is the silent fallback #91 rules out. `default
dict` covers a values file that sets failurePolicy itself to null (Helm then
deletes the key).

A set knob is VALIDATED HERE, at render time, by the same rule
go-common/failpolicy.FromEnv applies at startup (strconv.ParseInt base 10,
32-bit; retryTimes >= 0, failThreshold and cooldownMinutes >= 1). The pod
refuses a bad pin anyway, but only after the upgrade has rolled BOTH
deployments into a crashloop; `helm upgrade` refusing it keeps the running
pods. See fortiaigate.failurePolicyPin for the per-type rules and why the value
is re-printed rather than passed through.

Two more refusals ride along, both for the same reason — a pin the operator
believes in that the pods never see:
  - a key under fortiaigate.failurePolicy that is not one of the three knobs
    (a misspelt `failTreshold` would otherwise pin nothing, silently);
  - api.runtimeDefaults.{failThreshold,cooldownMinutes}, the Helm keys a
    reverted upstream mechanism shipped on br_8-0-2_dev for about a day
    (FAIG_BREAKER_* on the api pod, BELOW the stored org document). Nothing
    reads them now, and the replacement has the OPPOSITE precedence, so the
    move is refused loudly rather than dropped. Unset, "" and an empty map
    render fine, so a --reuse-values upgrade from that chart passes unless the
    operator actually set one.

Usage, inside a container's env list:
  {{- with (include "fortiaigate.failurePolicyEnv" . | trim) }}
  {{- . | nindent 8 }}
  {{- end }}
*/}}
{{- define "fortiaigate.failurePolicyEnv" -}}
{{- $rd := (.Values.api).runtimeDefaults -}}
{{- $flipped := "The precedence flipped with the move: an api.runtimeDefaults value was only a default that any field of an org's stored Runtime Defaults document beat, while a fortiaigate.failurePolicy pin OVERRIDES every org's stored document deployment-wide (and a PATCH of that field answers 422). Then remove api.runtimeDefaults" -}}
{{- if kindIs "map" $rd -}}
{{- range $key := list "failThreshold" "cooldownMinutes" -}}
{{- $old := index $rd $key -}}
{{- if and (not (kindIs "invalid" $old)) (ne (toString $old | trim) "") -}}
{{- fail (printf "api.runtimeDefaults.%s=%v is retired (#91): set fortiaigate.failurePolicy.%s instead. %s" $key $old $key $flipped) -}}
{{- end -}}
{{- end -}}
{{- else if and (not (kindIs "invalid" $rd)) (ne (toString $rd | trim) "") -}}
{{- fail (printf "api.runtimeDefaults is retired (#91): set fortiaigate.failurePolicy.{failThreshold,cooldownMinutes} instead. %s" $flipped) -}}
{{- end -}}
{{- $knobs := list (list "retryTimes" "FAIG_FAILURE_POLICY_RETRY_TIMES" 0) (list "failThreshold" "FAIG_FAILURE_POLICY_FAIL_THRESHOLD" 1) (list "cooldownMinutes" "FAIG_FAILURE_POLICY_COOLDOWN_MINUTES" 1) -}}
{{- $fp := (.Values.fortiaigate).failurePolicy | default dict -}}
{{- if not (kindIs "map" $fp) -}}
{{- fail (printf "fortiaigate.failurePolicy must be a map of retryTimes, failThreshold and cooldownMinutes, got %#v" $fp) -}}
{{- end -}}
{{- range $key := keys $fp | sortAlpha -}}
{{- if not (has $key (list "retryTimes" "failThreshold" "cooldownMinutes")) -}}
{{- fail (printf "fortiaigate.failurePolicy.%s is not a failure-policy knob; the knobs are retryTimes, failThreshold and cooldownMinutes (a misspelt key would pin nothing)" $key) -}}
{{- end -}}
{{- end -}}
{{- range $knob := $knobs }}
{{- $n := include "fortiaigate.failurePolicyPin" (dict "key" (printf "fortiaigate.failurePolicy.%s" (index $knob 0)) "value" (index $fp (index $knob 0)) "min" (index $knob 2)) }}
{{- if ne $n "" }}
- name: {{ index $knob 1 }}
  value: {{ $n | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
One failure-policy pin, validated and re-printed as plain decimal digits — or
"" when it is not pinned. Args: key (the values path, for the message), value,
min. Fails the render on anything go-common/failpolicy.FromEnv would refuse, so
a pin that renders is a pin both pods accept.

Re-printed, never passed through with toString, because of what Helm hands a
template. A number in a values FILE arrives as float64 (the YAML is decoded as
JSON), and toString prints a float64 of a million or more in exponent form:
`failThreshold: 1000000` would render "1e+06", which ParseInt refuses, and both
pods would crashloop on a value the operator wrote correctly. So, per type:
  - nil (unset, `null`): not pinned;
  - string (--set-string, a quoted YAML value): trimmed; blank = not pinned;
    otherwise it must be what ParseInt(s, 10, 32) accepts — an optional sign
    and decimal digits. Leading zeros are stripped before the conversion
    because sprig's int64 parses in base 0, where "010" is octal 8 and
    ParseInt reads 10; more than 10 significant digits is out of range before
    int64 could overflow;
  - float64 (a values-file number): must be integral — 1.5 is refused, and so
    is anything outside int32 before the int64 conversion, whose result for an
    out-of-range float Go leaves to the platform. An integral float is
    indistinguishable from the integer after Helm's decode, so `3.0` in a file
    renders "3";
  - int / int64 (--set, which parses integers itself): used as is;
  - anything else — a bool (`--set ...=true`), a map, a list — is refused.
Then the range: min (0 for retryTimes, 1 for the other two) to 2147483647.
*/}}
{{- define "fortiaigate.failurePolicyPin" -}}
{{- $v := .value -}}
{{- $n := 0 -}}
{{- $set := false -}}
{{- $why := printf "%s must be a whole number from %d to 2147483647, or empty to leave it unpinned; got %#v" .key .min $v -}}
{{- if kindIs "invalid" $v -}}
{{- else if kindIs "string" $v -}}
{{- $s := trim $v -}}
{{- if ne $s "" -}}
{{- if not (regexMatch "^[+-]?[0-9]+$" $s) -}}
{{- fail $why -}}
{{- end -}}
{{- $digits := regexReplaceAll "^[+-]?0*" $s "" | default "0" -}}
{{- if gt (len $digits) 10 -}}
{{- fail $why -}}
{{- end -}}
{{- $n = int64 $digits -}}
{{- if hasPrefix "-" $s -}}
{{- $n = sub 0 $n -}}
{{- end -}}
{{- $set = true -}}
{{- end -}}
{{- else if or (kindIs "float64" $v) (kindIs "float32" $v) -}}
{{- $f := float64 $v -}}
{{- if ne (floor $f) $f -}}
{{- fail $why -}}
{{- end -}}
{{- if or (lt $f -2147483648.0) (gt $f 2147483647.0) -}}
{{- fail (printf "%s must be a whole number from %d to 2147483647, or empty to leave it unpinned; got %.0f" .key .min $f) -}}
{{- end -}}
{{- $n = int64 $f -}}
{{- $set = true -}}
{{- else if has (kindOf $v) (list "int" "int8" "int16" "int32" "int64" "uint" "uint8" "uint16" "uint32" "uint64") -}}
{{- $n = int64 $v -}}
{{- $set = true -}}
{{- else -}}
{{- fail $why -}}
{{- end -}}
{{- if $set -}}
{{- if or (lt $n (int64 .min)) (gt $n 2147483647) -}}
{{- fail $why -}}
{{- end -}}
{{- printf "%d" $n -}}
{{- end -}}
{{- end }}

{{/*
Return the TLS secret name used by FortiAIGate workloads.
*/}}
{{- define "fortiaigate.tlsSecretName" -}}
{{- default "fortiaigate-tls-secret" .Values.tls.existingSecret }}
{{- end }}

{{/*
Return a checksum that changes when TLS material changes.
When Terraform manages the TLS secret, it passes tls.existingSecretChecksum.
When Helm manages the TLS secret, checksum the chart certificate files.
*/}}
{{- define "fortiaigate.tlsChecksum" -}}
{{- if .Values.tls.existingSecretChecksum }}
{{- .Values.tls.existingSecretChecksum }}
{{- else }}
{{- printf "%s%s" (tpl (.Files.Get .Values.tls.cert) $) (tpl (.Files.Get .Values.tls.key) $) | sha256sum }}
{{- end }}
{{- end }}

{{/* Internal serving certificate defaults to the shared application secret. */}}
{{- define "fortiaigate.internalTlsSecretName" -}}
{{- default (include "fortiaigate.tlsSecretName" .) .Values.tls.internalExistingSecret -}}
{{- end }}

{{- define "fortiaigate.internalTlsChecksum" -}}
{{- default (include "fortiaigate.tlsChecksum" .) .Values.tls.internalExistingSecretChecksum -}}
{{- end }}

{{- define "fortiaigate.dbTlsMountPath" -}}
{{- if .Values.tls.internalExistingSecret -}}
{{- .Values.tls.internalMountPath -}}
{{- else -}}
{{- .Values.tls.mountPath -}}
{{- end -}}
{{- end }}

{{- define "fortiaigate.dbTlsCAFile" -}}
{{- if .Values.tls.internalExistingSecret -}}ca.crt{{- else -}}tls.crt{{- end -}}
{{- end }}

{{/* Database TLS has a separate volume only when an internal secret is set. */}}
{{- define "fortiaigate.dbTlsVolumeMount" -}}
{{- if and .Values.tls.internalExistingSecret (or .Values.tls.enabled .Values.redis.tls.enabled .Values.postgresql.tls.enabled) }}
- name: internal-tls-certs
  mountPath: {{ .Values.tls.internalMountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "fortiaigate.dbTlsVolume" -}}
{{- if and .Values.tls.internalExistingSecret (or .Values.tls.enabled .Values.redis.tls.enabled .Values.postgresql.tls.enabled) }}
- name: internal-tls-certs
  secret:
    secretName: {{ include "fortiaigate.internalTlsSecretName" . }}
{{- end }}
{{- end }}

{{/* Placement is independent of deployment licensing. */}}
{{- define "fortiaigate.appPlacement" -}}
{{- with .Values.fortiaigate.appWorkloadPlacement.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.fortiaigate.appWorkloadPlacement.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "fortiaigate.gpuPlacement" -}}
{{- if .Values.fortiaigate.gpu.enabled }}
{{- with .Values.fortiaigate.gpuWorkloadPlacement.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.fortiaigate.gpuWorkloadPlacement.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- else }}
{{- include "fortiaigate.appPlacement" . }}
{{- end }}
{{- end }}

{{- define "fortiaigate.csrfSecretName" -}}
{{- default (printf "%s-csrf" (include "fortiaigate.fullname" .)) .Values.fortiaigate.env.csrfExistingSecret -}}
{{- end }}
