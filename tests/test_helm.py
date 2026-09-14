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
    },
    "triton": {"image": {"serverTag": "server-test-002", "modelsTag": "models-test-003"}},
    "tls": {"existingSecret": "fortiaigate-tls-secret"},
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
        "tls": {"certificatesSecret": "fortiaigate-tls-secret"},
        "primary": {"persistence": {
            "existingClaim": "", "storageClass": "managed-csi",
            "accessModes": ["ReadWriteOnce"],
        }},
    },
    "redis": {
        "tls": {"existingSecret": "fortiaigate-tls-secret"},
        "master": {"persistence": {
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
    return subprocess.run(args, input=yaml.safe_dump(values), text=True,
                          capture_output=True, check=True).stdout


def render(chart, values):
    return {(doc["kind"], doc["metadata"]["name"]): doc
            for doc in yaml.safe_load_all(helm("template", chart, values)) if doc}


class HelmContracts(unittest.TestCase):
    def test_both_charts_lint_with_required_values(self):
        for chart, values in [("fortiaigate", BASE), ("certmanager-issuer", ISSUER)]:
            with self.subTest(chart=chart):
                helm("lint", chart, values)

    def test_cpu_ingress_probes_and_storage(self):
        docs = render("fortiaigate", BASE)
        self.assertEqual(yaml.safe_load((ROOT / "fortiaigate" / "Chart.yaml").read_text())["version"], "8.0.1")
        self.assertNotIn(("Deployment", "triton-server"), docs)
        ingress = docs["Ingress", "fortiaigate-ingress"]
        self.assertEqual(ingress["spec"]["ingressClassName"], "azure-application-gateway")
        self.assertEqual(ingress["spec"]["rules"][0]["host"], "fortiaigate.example.com")
        routes = {path["path"]: path["backend"]["service"]["name"] for path in
                  ingress["spec"]["rules"][0]["http"]["paths"]}
        self.assertEqual(routes, {"/ui": "webui", "/api/": "api", "/": "core"})
        self.assertEqual(ingress["metadata"]["annotations"], BASE["ingress"]["annotations"])
        self.assertEqual(ingress["spec"]["tls"][0]["secretName"], "fortiaigate-tls-secret")
        self.assertNotIn(("Secret", "fortiaigate-tls-secret"), docs)
        for name, path in [("core", "/fortiaigate/health/readiness"),
                           ("api", "/openapi.json"), ("webui", "/ui")]:
            container = docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]
            probe = container["readinessProbe"]["httpGet"]
            self.assertEqual(probe["path"], path)
            self.assertEqual(probe["scheme"], "HTTPS")
        core_env = {entry["name"]: entry.get("value") for entry in
                    docs["Deployment", "core"]["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(core_env["UPSTREAM_TLS_VERIFY"], "true")
        self.assertEqual(core_env["SCANNER_MAX_SCAN_CHARS"], "5000")
        self.assertEqual(len(yaml.safe_load(core_env["SCANNER_MAX_SCAN_CHARS_BY_NAME"])), 8)
        for name in ("sensitive-scanner", "anonymize-scanner"):
            env = {entry["name"]: entry.get("value") for entry in
                   docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]["env"]}
            self.assertEqual(env["CHUNK_SIZE"], "256")
            self.assertEqual(env["CHUNK_OVERLAP_SIZE"], "64")
        shared = docs["PersistentVolumeClaim", "fortiaigate-storage"]["spec"]
        self.assertEqual(shared["storageClassName"], "azurefile-fortiaigate")
        self.assertEqual(shared["accessModes"], ["ReadWriteMany"])
        self.assertEqual(shared["resources"]["requests"]["storage"], "123Gi")
        for name in ("core", "api", "webui", "logd", "license-manager"):
            doc = docs.get(("Deployment", name)) or docs.get(("DaemonSet", name))
            self.assertIsNotNone(doc, name)
            image = doc["spec"]["template"]["spec"]["containers"][0]["image"]
            self.assertTrue(image.startswith("registry.example/fortiaigate/"), image)
            self.assertTrue(image.endswith(":app-test-001"), image)
            if doc["kind"] == "Deployment":
                self.assertEqual(doc["spec"]["strategy"]["type"], "Recreate")
        databases = [doc for (kind, _), doc in docs.items() if kind == "StatefulSet"]
        self.assertEqual(len(databases), 2)
        for database in databases:
            claim = database["spec"]["volumeClaimTemplates"][0]["spec"]
            self.assertEqual(claim["storageClassName"], "managed-csi")
            self.assertEqual(claim["accessModes"], ["ReadWriteOnce"])

    def test_gpu_placement_and_licensed_hostnames(self):
        values = copy.deepcopy(BASE)
        values["fortiaigate"]["gpu"]["enabled"] = True
        values["fortiaigate"]["gpuWorkloadPlacement"] = {
            "nodeSelector": {"fortiaigate-role": "gpu"},
            "tolerations": [{"key": "fortiaigate-gpu", "operator": "Equal",
                             "value": "true", "effect": "NoSchedule"}],
        }
        values["global"] = {"licenses": {"aks-app-test": "", "aks-gpu-test": ""}}
        values["license"] = {"existingConfigMap": "fortiaigate-license-config"}
        docs = render("fortiaigate", values)
        pod = docs["Deployment", "triton-server"]["spec"]["template"]["spec"]
        self.assertEqual(pod["initContainers"][0]["image"],
                         "registry.example/fortiaigate/triton-models:models-test-003")
        self.assertEqual(pod["containers"][0]["image"],
                         "registry.example/fortiaigate/custom-triton:server-test-002")
        model_data = docs["ConfigMap", "triton-model-repository"]["data"]
        self.assertEqual(set(model_data), {
            "prompt_injection_model-config.pbtxt", "toxicity_model-config.pbtxt",
            "sensitive_model-config.pbtxt", "language_model-config.pbtxt",
        })
        for mount in pod["containers"][0]["volumeMounts"]:
            if mount["name"] == "model-configs":
                self.assertIn(mount["subPath"], model_data)
        self.assertEqual(pod["nodeSelector"]["fortiaigate-role"], "gpu")
        self.assertIn(values["fortiaigate"]["gpuWorkloadPlacement"]["tolerations"][0], pod["tolerations"])
        terms = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
        self.assertEqual(set(terms[0]["matchExpressions"][0]["values"]),
                         {"aks-app-test", "aks-gpu-test"})

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


if __name__ == "__main__":
    unittest.main()
