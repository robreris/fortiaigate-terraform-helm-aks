"""Offline chart contract checks using representative AKS values.

These check rendered Kubernetes objects, not Terraform's value composition or
live admission. No cluster connection, license files, or registry access needed.
"""

import copy
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
BASE = {
    "fortiaigate": {
        "gpu": {"enabled": False},
        "image": {"repository": "registry.example/fortiaigate", "tag": "app-test-001"},
        "updateStrategy": "Recreate",
        "appWorkloadPlacement": {"nodeSelector": {"fortiaigate-role": "app"}},
        "gpuWorkloadPlacement": {
            "nodeSelector": {"fortiaigate-role": "gpu"},
            "tolerations": [{"key": "fortiaigate-gpu", "operator": "Equal",
                             "value": "true", "effect": "NoSchedule"}],
        },
        "env": {"csrfExistingSecret": "application-secret"},
    },
    "triton": {"image": {"serverTag": "server-test-002", "modelsTag": "models-test-003"}},
    "vllm": {"gpuAttach": "shared", "image": {"tag": "vllm-test-004"}},
    "api": {"masterKeyExistingSecret": "application-secret"},
    "tls": {"existingSecret": "fortiaigate-tls-secret", "existingSecretChecksum": "web-1",
            "internalExistingSecret": "internal-secret", "internalExistingSecretChecksum": "internal-1"},
    "ingress": {
        "className": "azure-application-gateway",
        "host": "fortiaigate.example.com",
        "annotations": {
            "appgw.ingress.kubernetes.io/backend-protocol": "https",
            "appgw.ingress.kubernetes.io/ssl-redirect": "true",
        },
    },
    "storage": {"storageClass": "azurefile-fortiaigate", "size": "123Gi"},
    "postgresql": {
        "auth": {"existingSecret": "fortiaigate-postgresql"},
        "tls": {"certificatesSecret": "internal-secret"},
        "primary": {"nodeSelector": {"fortiaigate-role": "app"}, "persistence": {
            "existingClaim": "", "storageClass": "managed-csi",
            "accessModes": ["ReadWriteOnce"],
        }},
    },
    "redis": {
        "auth": {"existingSecret": "fortiaigate-redis"},
        "tls": {"existingSecret": "internal-secret", "certCAFilename": "ca.crt"},
        "master": {"nodeSelector": {"fortiaigate-role": "app"}, "persistence": {
            "existingClaim": "", "storageClass": "managed-csi",
            "accessModes": ["ReadWriteOnce"],
        }},
    },
}
ISSUER = {
    "email": "operator@example.com", "host": "fortiaigate.example.com",
    "dnsZone": {
        "name": "example.com", "resourceGroup": "dns-test",
        "subscriptionID": "00000000-0000-0000-0000-000000000000",
    },
    "managedIdentityClientID": "11111111-1111-1111-1111-111111111111",
}


def helm(command, chart, values):
    args = ["helm", command]
    if command == "template":
        args.append("fortiaigate")
    args += [str(ROOT / chart), "--namespace", "fortiaigate", "-f", "-"]
    result = subprocess.run(args, input=yaml.safe_dump(values), text=True, capture_output=True)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, args, result.stdout, result.stderr)
    return result.stdout


def render(chart, values):
    return {(doc["kind"], doc["metadata"]["name"]): doc
            for doc in yaml.safe_load_all(helm("template", chart, values)) if doc}


class HelmContracts(unittest.TestCase):
    def test_both_charts_lint_with_required_values(self):
        for chart, values in [("fortiaigate", BASE), ("certmanager-issuer", ISSUER)]:
            with self.subTest(chart=chart):
                helm("lint", chart, values)

    def test_cpu_ingress_probes_storage_and_licensing(self):
        docs = render("fortiaigate", BASE)
        self.assertEqual(yaml.safe_load((ROOT / "fortiaigate/Chart.yaml").read_text())["version"], "8.0.2")
        self.assertNotIn(("Deployment", "core"), docs)
        self.assertNotIn(("Deployment", "vllm-server"), docs)
        self.assertNotIn(("Deployment", "dp-agent"), docs)
        for (_, name) in docs:
            self.assertNotIn(name, ("language-scanner", "code-scanner", "fortiaigate-license-config"))
        triton = docs["Deployment", "triton-server"]["spec"]["template"]["spec"]
        self.assertNotIn("nvidia.com/gpu", triton["containers"][0]["resources"]["limits"])
        self.assertEqual(triton["nodeSelector"], {"fortiaigate-role": "app"})
        ingress = docs["Ingress", "fortiaigate-ingress"]
        self.assertEqual(ingress["spec"]["ingressClassName"], "azure-application-gateway")
        self.assertEqual(ingress["metadata"]["annotations"], BASE["ingress"]["annotations"])
        self.assertEqual(ingress["spec"]["tls"][0]["secretName"], "fortiaigate-tls-secret")
        routes = {p["path"]: p["backend"]["service"]["name"] for p in
                  ingress["spec"]["rules"][0]["http"]["paths"]}
        self.assertEqual(routes, {"/ui": "webui", "/api/": "api", "/ai": "llm-gateway", "/": "webui"})
        for name, path in [("api", "/openapi.json"), ("webui", "/ui"),
                           ("llm-gateway", "/fortiaigate/health/readiness")]:
            c = docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]
            self.assertEqual(c["readinessProbe"]["httpGet"]["path"], path)
            self.assertEqual(c["readinessProbe"]["httpGet"]["scheme"], "HTTPS")
        lm = docs["Deployment", "license-manager"]
        self.assertEqual(lm["spec"]["replicas"], 2)
        self.assertNotIn(("DaemonSet", "license-manager"), docs)
        self.assertNotIn("internalTrafficPolicy", docs["Service", "license-manager"]["spec"])
        for (kind, name), d in docs.items():
            if kind in ("Deployment", "StatefulSet"):
                pod = d["spec"]["template"]["spec"]
                self.assertNotIn("nodeAffinity", pod.get("affinity", {}), name)
                self.assertEqual(pod["nodeSelector"], {"fortiaigate-role": "app"}, name)
        shared = docs["PersistentVolumeClaim", "fortiaigate-storage"]["spec"]
        self.assertEqual(shared["storageClassName"], "azurefile-fortiaigate")
        self.assertEqual(shared["accessModes"], ["ReadWriteMany"])
        self.assertEqual(shared["resources"]["requests"]["storage"], "123Gi")
        for name in ("fortiaigate-postgresql", "fortiaigate-redis-master"):
            claim = docs["StatefulSet", name]["spec"]["volumeClaimTemplates"][0]["spec"]
            self.assertEqual(claim["storageClassName"], "managed-csi")
            self.assertEqual(claim["accessModes"], ["ReadWriteOnce"])

    def test_shared_and_dedicated_gpu_placement_and_images(self):
        for mode in ("shared", "dedicated"):
            values = copy.deepcopy(BASE)
            values["fortiaigate"]["gpu"]["enabled"] = True
            values["vllm"]["gpuAttach"] = mode
            docs = render("fortiaigate", values)
            name = "triton-vllm-server" if mode == "shared" else "triton-server"
            pod = docs["Deployment", name]["spec"]["template"]["spec"]
            triton = next(c for c in pod["containers"] if c["name"] == "triton")
            self.assertEqual(triton["image"], "registry.example/fortiaigate/custom-triton:server-test-002")
            self.assertEqual(triton["resources"]["limits"]["nvidia.com/gpu"], 1)
            for c in pod["initContainers"]:
                if c["name"].endswith("model-loader"):
                    self.assertEqual(c["image"], "registry.example/fortiaigate/faig-models:models-test-003")
            gpu_pods = [pod]
            if mode == "shared":
                self.assertNotIn(("Deployment", "vllm-server"), docs)
                vllm = next(c for c in pod["containers"] if c["name"] == "vllm")
                self.assertNotIn("nvidia.com/gpu", vllm["resources"]["limits"])
                probe = next(c for c in pod["initContainers"] if c["name"] == "gpu-probe")
                self.assertEqual(probe["image"], "registry.example/fortiaigate/vllm-server:vllm-test-004")
                self.assertEqual(probe["resources"]["limits"]["nvidia.com/gpu"], 1)
                self.assertIn(("Role", name), docs)
                self.assertEqual(docs["Service", "triton-server"]["spec"]["selector"]["app"], name)
            else:
                vpod = docs["Deployment", "vllm-server"]["spec"]["template"]["spec"]
                gpu_pods.append(vpod)
                vllm = vpod["containers"][0]
                self.assertEqual(vllm["resources"]["limits"]["nvidia.com/gpu"], 1)
            self.assertEqual(vllm["image"], "registry.example/fortiaigate/vllm-server:vllm-test-004")
            for gp in gpu_pods:
                self.assertEqual(gp["nodeSelector"], {"fortiaigate-role": "gpu"})
                self.assertIn(values["fortiaigate"]["gpuWorkloadPlacement"]["tolerations"][0], gp["tolerations"])
                self.assertNotIn("nodeAffinity", gp.get("affinity", {}))
            model_data = docs["ConfigMap", "triton-model-repository"]["data"]
            self.assertEqual(set(model_data), {"sensitive_model-config.pbtxt"})
            for c in pod["containers"]:
                for mount in c.get("volumeMounts", []):
                    if mount["name"] == "model-configs":
                        self.assertIn(mount["subPath"], model_data)

    def test_certificate_modes(self):
        for environment in ("staging", "production"):
            values = copy.deepcopy(ISSUER)
            values["issuerName"] = "letsencrypt-" + environment
            server = ("https://acme-v02.api.letsencrypt.org/directory" if environment == "production"
                      else "https://acme-staging-v02.api.letsencrypt.org/directory")
            values["acmeServer"] = server
            with self.subTest(environment=environment):
                docs = render("certmanager-issuer", values)
                issuer = docs["ClusterIssuer", values["issuerName"]]
                self.assertEqual(issuer["spec"]["acme"]["server"], server)
                certificate = next(doc for (kind, _), doc in docs.items() if kind == "Certificate")
                self.assertEqual(certificate["spec"]["dnsNames"], [ISSUER["host"]])
                self.assertEqual(certificate["spec"]["secretName"], BASE["tls"]["existingSecret"])
                self.assertEqual(certificate["spec"]["issuerRef"]["name"], values["issuerName"])

    def test_certificate_missing_required_values_fails(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render("certmanager-issuer", {})

    def test_separate_web_and_internal_tls_and_shared_master_key(self):
        values = copy.deepcopy(BASE)
        values["tls"]["reloaderEnabled"] = True
        # The optional chart path remains valid, though Terraform disables it
        # until a matching image is supplied and qualified.
        values["dpAgent"] = {"enabled": True, "masterKeyExistingSecret": "application-secret"}
        docs = render("fortiaigate", values)
        for name in ("api", "llm-gateway", "logd", "license-manager", "dp-agent"):
            pod = docs["Deployment", name]["spec"]["template"]["spec"]
            c = pod["containers"][0]
            env = {e["name"]: e.get("value") for e in c["env"]}
            self.assertEqual(env["POSTGRES_SSL_ENABLED"], "true", name)
            self.assertEqual(env["POSTGRES_SSL_CA_CERTS"], "/etc/internal-tls/ca.crt", name)
            self.assertEqual(env["SSL_CERT_FILE"], "/etc/internal-tls/ca.crt", name)
            if name != "license-manager":
                self.assertEqual(env["REDIS_SSL_CA_CERTS"], "/etc/internal-tls/ca.crt", name)
            volumes = {v["name"]: v for v in pod["volumes"]}
            self.assertEqual(volumes["internal-tls-certs"]["secret"]["secretName"], "internal-secret")
            serving = "fortiaigate-tls-secret" if name in ("api", "llm-gateway") else "internal-secret"
            self.assertEqual(volumes["tls-certs"]["secret"]["secretName"], serving)
            mounts = {m["name"]: m for m in c["volumeMounts"]}
            self.assertEqual(mounts["internal-tls-certs"]["mountPath"], "/etc/internal-tls")
        for name in ("api", "llm-gateway", "webui"):
            self.assertEqual(docs["Deployment", name]["metadata"]["annotations"]
                             ["secret.reloader.stakater.com/reload"], "fortiaigate-tls-secret")
        for name in ("guardrail", "dlp-scanner", "policy-guard"):
            pod = docs["Deployment", name]["spec"]["template"]
            self.assertEqual(pod["metadata"]["annotations"]["checksum/tls"], "internal-1")
            self.assertEqual(pod["spec"]["volumes"][0]["secret"]["secretName"], "internal-secret")
        for name in ("api", "llm-gateway", "guardrail", "dp-agent"):
            env = docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]["env"]
            master = next(e for e in env if e["name"] == "FAIG_MASTER_KEY")
            self.assertEqual(master["valueFrom"]["secretKeyRef"], {"name": "application-secret", "key": "master-key"})
        for name in ("fortiaigate-postgresql", "fortiaigate-redis-master"):
            volumes = docs["StatefulSet", name]["spec"]["template"]["spec"]["volumes"]
            secrets = [v["secret"]["secretName"] for v in volumes if "secret" in v]
            self.assertIn("internal-secret", secrets)
            self.assertNotIn("fortiaigate-tls-secret", secrets)
        for name in ("fortiaigate-tls-secret", "fortiaigate-master-key", "fortiaigate-csrf", "fortiaigate-redis"):
            self.assertNotIn(("Secret", name), docs)

    def test_tls_rollouts_are_independent(self):
        values = copy.deepcopy(BASE)
        before = render("fortiaigate", values)
        values["tls"]["existingSecretChecksum"] = "web-2"
        web = render("fortiaigate", values)
        for name in ("api", "llm-gateway", "webui"):
            self.assertNotEqual(before["Deployment", name]["spec"]["template"], web["Deployment", name]["spec"]["template"])
        for name in ("logd", "license-manager", "guardrail", "dlp-scanner", "policy-guard"):
            self.assertEqual(before["Deployment", name]["spec"]["template"], web["Deployment", name]["spec"]["template"])
        values["tls"]["internalExistingSecretChecksum"] = "internal-2"
        internal = render("fortiaigate", values)
        for name in ("api", "llm-gateway", "logd", "license-manager", "guardrail", "dlp-scanner", "policy-guard"):
            self.assertNotEqual(web["Deployment", name]["spec"]["template"], internal["Deployment", name]["spec"]["template"])
        self.assertEqual(web["Deployment", "webui"]["spec"]["template"], internal["Deployment", "webui"]["spec"]["template"])

    def test_shared_tls_fallback_and_disabled_database_tls(self):
        values = copy.deepcopy(BASE)
        values["tls"]["internalExistingSecret"] = ""
        docs = render("fortiaigate", values)
        pod = docs["Deployment", "llm-gateway"]["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        self.assertEqual(env["POSTGRES_SSL_CA_CERTS"], "/etc/tls/tls.crt")
        self.assertNotIn("internal-tls-certs", {v["name"] for v in pod["volumes"]})
        values["postgresql"]["tls"]["enabled"] = False
        values["redis"]["tls"]["enabled"] = False
        docs = render("fortiaigate", values)
        for name in ("api", "llm-gateway", "logd", "license-manager"):
            c = docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]
            self.assertNotIn("POSTGRES_SSL_CA_CERTS", {e["name"] for e in c["env"]})

    def test_invalid_master_key_and_gpu_modes_fail(self):
        for changes in ({"dpAgent": {"masterKeyExistingSecret": "different-secret"}},
                        {"vllm": {"gpuAttach": "shared-runtime"}}):
            values = copy.deepcopy(BASE)
            values["fortiaigate"]["gpu"]["enabled"] = True
            values.update(changes)
            with self.assertRaises(subprocess.CalledProcessError):
                render("fortiaigate", values)

    def test_missing_tls_material_fails_and_explicit_csrf_value_is_valid(self):
        values = copy.deepcopy(BASE)
        values["tls"]["existingSecret"] = ""
        with self.assertRaises(subprocess.CalledProcessError):
            render("fortiaigate", values)
        values = copy.deepcopy(BASE)
        values["fortiaigate"]["env"]["csrfSecretKey"] = "fixed-test-value"
        docs = render("fortiaigate", values)
        env = docs["Deployment", "api"]["spec"]["template"]["spec"]["containers"][0]["env"]
        entry = next(e for e in env if e["name"] == "CSRF_SECRET_KEY")
        self.assertEqual(entry, {"name": "CSRF_SECRET_KEY", "value": "fixed-test-value"})

    def test_release_default_images(self):
        values = copy.deepcopy(BASE)
        values.pop("triton")
        values["vllm"] = {"gpuAttach": "shared"}
        values["fortiaigate"]["gpu"]["enabled"] = True
        values["fortiaigate"]["image"]["tag"] = "V8.0.2-build0047"
        docs = render("fortiaigate", values)
        images = set()
        for (kind, _), doc in docs.items():
            if kind in ("Deployment", "StatefulSet"):
                pod = doc["spec"]["template"]["spec"]
                images.update(c["image"].removeprefix("registry.example/fortiaigate/")
                              for c in pod.get("initContainers", []) + pod.get("containers", [])
                              if c["image"].startswith("registry.example/fortiaigate/"))
        expected = {f"{name}:V8.0.2-build0047" for name in
                    ("api", "webui", "llm-gateway", "guardrail", "guardrail-scanner", "license_manager", "logd")}
        expected.update({"custom-triton:25.11-onnx-trt-agt-rpt-s1", "faig-models:0.0.4-s1", "vllm-server:0.28.0-rpt-s1"})
        self.assertEqual(images, expected)

    def test_custom_web_secret_and_disabled_tls_mounts(self):
        values = copy.deepcopy(BASE)
        values["tls"].update({"existingSecret": "custom-web-secret", "reloaderEnabled": True})
        docs = render("fortiaigate", values)
        self.assertEqual(docs["Ingress", "fortiaigate-ingress"]["spec"]["tls"][0]["secretName"],
                         "custom-web-secret")
        for name in ("api", "llm-gateway", "webui"):
            doc = docs["Deployment", name]
            self.assertEqual(doc["metadata"]["annotations"]["secret.reloader.stakater.com/reload"],
                             "custom-web-secret")
            volumes = doc["spec"]["template"]["spec"]["volumes"]
            self.assertEqual(next(v for v in volumes if v["name"] == "tls-certs")
                             ["secret"]["secretName"], "custom-web-secret")
        values["tls"]["enabled"] = False
        values["tls"]["reloaderEnabled"] = False
        values["postgresql"]["tls"]["enabled"] = False
        values["redis"]["tls"]["enabled"] = False
        docs = render("fortiaigate", values)
        for (kind, name), doc in docs.items():
            if kind == "Deployment":
                pod = doc["spec"]["template"]["spec"]
                self.assertFalse({"tls-certs", "internal-tls-certs"} &
                                 {v["name"] for v in pod.get("volumes", [])}, name)
                for c in pod["containers"]:
                    self.assertNotIn("SSL_CERT_FILE", {e["name"] for e in c.get("env", [])}, name)

    def test_failure_policy_pins_are_shared_and_validated(self):
        values = copy.deepcopy(BASE)
        values["fortiaigate"]["failurePolicy"] = {
            "retryTimes": 0, "failThreshold": 4, "cooldownMinutes": 7,
        }
        docs = render("fortiaigate", values)
        for name in ("api", "llm-gateway"):
            env = {e["name"]: e.get("value") for e in
                   docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]["env"]}
            self.assertEqual(env["FAIG_FAILURE_POLICY_RETRY_TIMES"], "0")
            self.assertEqual(env["FAIG_FAILURE_POLICY_FAIL_THRESHOLD"], "4")
            self.assertEqual(env["FAIG_FAILURE_POLICY_COOLDOWN_MINUTES"], "7")
        values["fortiaigate"]["failurePolicy"]["failThreshold"] = 0
        with self.assertRaises(subprocess.CalledProcessError):
            render("fortiaigate", values)


if __name__ == "__main__":
    unittest.main()
