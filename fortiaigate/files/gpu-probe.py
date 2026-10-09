"""gpu-probe: record which GPU the kubelet gave this pod, so a container with
no GPU request of its own can attach the very same card.

The co-located Triton pod — Deployment triton-vllm-server, labelled
app=triton-vllm-server (templates/triton-server.yaml, vllm.gpuAttach shared) —
runs Triton and the policyGuard vLLM server side by side on ONE card. Triton gets the card from the device plugin. vLLM must not request a
card — the plugin hands out whole cards, so a request would be a SECOND card,
Pending on a one-card node and a second licence on a two-card one — and the
NVIDIA container runtime will attach whatever NVIDIA_VISIBLE_DEVICES names
instead. The one thing nobody knows at render time is WHICH card the device
plugin will pick. This initContainer finds out:

  1. It requests the same GPU resource and count as the Triton container
     (the chart renders both from triton.resources.limits). The kubelet
     allocates it a card, and the device manager hands the devices a finished
     initContainer held to the app containers of the same pod that request the
     same resource — so Triton reuses exactly this card. The pod's effective
     request is max(init, sum of app containers) = one allocation, not two.
  2. It reads the card from NVML through the runtime-injected nvidia-smi
     (`nvidia-smi -L`), NEVER from NVIDIA_VISIBLE_DEVICES: the runtime consumes
     that variable when it injects the card and leaves `void` behind
     (verified on the lab, design doc § 9). The variable is a
     fallback only when the runtime left real UUIDs in it (CDI).
  3. It PATCHes its own pod: metadata.annotations[GPU_ANNOTATION] = the UUIDs,
     comma-joined and sorted. The vllm container takes NVIDIA_VISIBLE_DEVICES
     from that annotation through the downward API (fieldRef), so the runtime
     attaches Triton's card there too. Inside, both engines see CUDA device 0.
  4. It reads the annotation back, waits GPU_PROBE_SETTLE seconds so the
     kubelet's watch has the patched pod before it creates the next container
     (0 s raced in 3 of 3 lab runs, 2 s and 5 s never did), and exits 0.

It NEVER GUESSES (the rule of Mantis 1348127, kept): when no card is visible
it exits non-zero with the reason as its termination message
(`kubectl describe pod`), the kubelet retries it, and the pod never starts a
vLLM on a card that might be another pod's. When nvidia-smi shows MORE cards
than the pod asked for (a runtime exposing `all`), it refuses too: one of
them would be a card Triton does not hold, and the licence counts every card
an engine can see.

Stdlib only, run with `python3 -S`: the vllm-server image it runs in starts
the GPU licence reporter from a .pth in every ordinary interpreter, and this
helper must not stand up a reporter whose card Triton is about to take over.

Environment (all set by the chart):
  POD_NAME POD_NAMESPACE      downward API
  GPU_ANNOTATION              the annotation key to write (fortiaigate.io/gpu-device)
  GPU_PROBE_EXPECT_COUNT      cards the pod asked for (triton gpuCount); a
                              different count visible is a refusal. Unset: any
  GPU_PROBE_SETTLE            seconds to wait after the patch (5)
  GPU_PROBE_DRY_RUN           1 = decide and print, never touch the API (tests)
  NVIDIA_VISIBLE_DEVICES      what the runtime left (void after injection)
"""
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
# The container's terminationMessagePath (the Kubernetes default): what this
# file holds when the init exits is what `kubectl describe pod` shows.
TERMINATION_LOG = "/dev/termination-log"
# `nvidia-smi -L` lines: "GPU 0: NVIDIA L4 (UUID: GPU-...)" and, under a
# MIG-enabled card, "  MIG 3g.20gb Device 0: (UUID: MIG-...)".
UUID_RE = re.compile(r"\(UUID:\s*((?:GPU|MIG)-[0-9A-Za-z-]+)\)")
DEFAULT_ANNOTATION = "fortiaigate.io/gpu-device"


def log(msg):
    print("gpu-probe: " + msg, flush=True)


def env(name, default=None):
    v = os.environ.get(name, "")
    return v if v != "" else default


def parse_nvidia_smi_list(text):
    """The UUIDs `nvidia-smi -L` lists: the MIG slices when any are listed —
    the plugin handed out slices, and the parent card's line is only their
    frame — else the whole cards."""
    uuids = UUID_RE.findall(text)
    migs = [u for u in uuids if u.startswith("MIG-")]
    return migs or uuids


def visible_from_nvidia_smi(run=subprocess.run):
    """The devices the runtime injected, from NVML. None when nvidia-smi is not
    in this container or fails (the runtime did not inject anything, or the
    `utility` capability is missing); [] when it answers with no device."""
    try:
        out = run(["nvidia-smi", "-L"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        log("nvidia-smi -L: %s" % e)
        return None
    if out.returncode != 0:
        log("nvidia-smi -L exited %d: %s" % (out.returncode, (out.stderr or out.stdout).strip()))
        return None
    return parse_nvidia_smi_list(out.stdout)


def visible_from_env(value):
    """The device plugin's own NVIDIA_VISIBLE_DEVICES, when the runtime left
    it in place: a list of GPU-/MIG- UUIDs. `void` (what the runtime leaves
    after injecting), `all`, `none`, an empty value and bare host indices are
    never used — an index is not a card, and `all` is the one value that
    would hand vLLM every card on the node."""
    uuids = [u.strip() for u in (value or "").split(",") if u.strip()]
    if uuids and all(u.startswith(("GPU-", "MIG-")) for u in uuids):
        return uuids
    return []


def devices(expect, run=subprocess.run):
    """(sorted UUIDs, where they came from) for the card(s) this container
    holds, or ([], why not). Never a guess."""
    raw_env = os.environ.get("NVIDIA_VISIBLE_DEVICES", "")
    log("NVIDIA_VISIBLE_DEVICES as this container sees it: %r" % raw_env)
    smi = visible_from_nvidia_smi(run)
    if smi:
        uuids, source = sorted(set(smi)), "nvidia-smi"
    else:
        from_env = visible_from_env(raw_env)
        if from_env:
            uuids, source = sorted(set(from_env)), "NVIDIA_VISIBLE_DEVICES"
        elif smi is None:
            return [], ("no GPU is visible: nvidia-smi is not in this container, so the NVIDIA container "
                        "runtime injected nothing (is it containerd's default runtime, and does the device "
                        "plugin allocate %s to this pod?), and NVIDIA_VISIBLE_DEVICES=%r names no card"
                        % (env("GPU_PROBE_RESOURCE", "the GPU resource"), raw_env))
        else:
            return [], ("no GPU is visible: nvidia-smi lists no device and NVIDIA_VISIBLE_DEVICES=%r "
                        "names no card" % raw_env)
    if expect and len(uuids) != expect:
        return [], ("%d card(s) visible (%s via %s) but this pod asked for %d: one of them would be a card "
                    "Triton does not hold, and the licence counts every card an engine can see. Check the "
                    "device plugin's allocation and the runtime's NVIDIA_VISIBLE_DEVICES handling"
                    % (len(uuids), ",".join(uuids), source, expect))
    return uuids, source


def k8s(method, path, body=None):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(os.path.join(SA_DIR, "token")) as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://%s:%s%s" % (host, port, path), data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/merge-patch+json")
    try:
        with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode("utf-8", "replace")}
    except (urllib.error.URLError, OSError) as e:
        return 0, {"error": str(e)}


def patch_annotation(namespace, pod, key, value, api=k8s):
    """Write the annotation on this pod and read it back. (True, "") or
    (False, why) — the why names the RBAC grant when the API refused."""
    path = "/api/v1/namespaces/%s/pods/%s" % (namespace, pod)
    status, resp = api("PATCH", path, {"metadata": {"annotations": {key: value}}})
    if status < 200 or status >= 300:
        why = "PATCH pod %s/%s -> HTTP %d: %s" % (namespace, pod, status, resp.get("error", resp))
        if status in (401, 403):
            why += (". The gpu-probe initContainer patches its OWN pod's annotation and needs pods get+patch "
                    "in this namespace (Role/RoleBinding triton-vllm-server, rendered by the chart in shared mode)")
        return False, why
    status, resp = api("GET", path)
    got = ((resp.get("metadata") or {}).get("annotations") or {}).get(key)
    if status < 200 or status >= 300 or got != value:
        return False, "read-back of pod %s/%s annotation %s failed (HTTP %d, got %r, wrote %r)" % (
            namespace, pod, key, status, got, value)
    return True, ""


def give_up(msg, dry_run):
    """Exit non-zero with `msg` as the termination message: `kubectl describe
    pod` shows it under the initContainer's last state, the pod stays
    unready, and the kubelet retries the initContainer with backoff."""
    log(msg)
    if not dry_run:
        try:
            with open(TERMINATION_LOG, "w") as f:
                f.write(msg + "\n")
        except OSError as e:
            log("could not write %s: %s" % (TERMINATION_LOG, e))
    sys.exit(1)


def main():
    pod = env("POD_NAME", "?")
    namespace = env("POD_NAMESPACE", "default")
    key = env("GPU_ANNOTATION", DEFAULT_ANNOTATION)
    expect = int(env("GPU_PROBE_EXPECT_COUNT", "0") or 0)
    settle = float(env("GPU_PROBE_SETTLE", "5"))
    dry_run = env("GPU_PROBE_DRY_RUN", "0") == "1"

    log("finding the GPU the kubelet gave pod %s/%s%s" % (
        namespace, pod, " (expecting %d card(s))" % expect if expect else ""))
    uuids, source = devices(expect)
    if not uuids:
        give_up("gpu-probe refuses to name a card for pod %s/%s: %s. No card is guessed instead: the "
                "kubelet retries this initContainer, and vLLM starts only on the card Triton holds."
                % (namespace, pod, source), dry_run)
    value = ",".join(uuids)
    log("this pod holds %s (from %s); the vllm container will attach it as NVIDIA_VISIBLE_DEVICES"
        % (value, source))
    if dry_run:
        print(value)
        return
    ok, why = patch_annotation(namespace, pod, key, value)
    if not ok:
        give_up(why, dry_run)
    log("annotation %s=%s written and read back; settling %.0fs for the kubelet" % (key, value, settle))
    time.sleep(settle)


if __name__ == "__main__":
    main()
