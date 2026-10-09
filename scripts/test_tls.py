#!/usr/bin/env python3
"""Run mocked TLS tests from a temporary checkout without local state/tfvars.

Requires Terraform 1.7+ and OpenSSL. Run terraform init -backend=false first
so the locked provider binaries are available. No remote resources are created.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="fortiaigate-tls-tests-") as directory:
        target = Path(directory)
        for path in ROOT.glob("*.tf"):
            if path.name != "backend.tf":
                shutil.copy2(path, target / path.name)
        # Mock plans do not synthesize AKS's absent optional kubelet block.
        # Supply a fixture identity for unrelated storage role assignments.
        (target / "tls_test_override.tf").write_text('''
resource "azurerm_kubernetes_cluster" "this" {
  identity {
    type = "UserAssigned"
    identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cluster"]
  }
  kubelet_identity {
    client_id = "22222222-2222-2222-2222-222222222222"
    object_id = "11111111-1111-1111-1111-111111111111"
    user_assigned_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/kubelet"
  }
}
''')
        shutil.copy2(ROOT / ".terraform.lock.hcl", target)
        for name in ("fortiaigate", "certmanager-issuer", "tests/terraform"):
            shutil.copytree(ROOT / name, target / name)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", "test-key.pem", "-out", "test-cert.pem", "-days", "1",
            "-subj", "/CN=fortiaigate.example.com",
            "-addext", "subjectAltName=DNS:fortiaigate.example.com",
        ], cwd=target, check=True, capture_output=True)
        subprocess.run([
            "terraform", "init", "-backend=false", "-lockfile=readonly", "-no-color",
            "-plugin-dir=" + str(ROOT / ".terraform/providers"),
        ], cwd=target, check=True)
        subprocess.run([
            "terraform", "validate", "-no-color",
        ], cwd=target, check=True)
        subprocess.run([
            "terraform", "test", "-test-directory=tests/terraform", "-no-color",
        ], cwd=target, check=True)


if __name__ == "__main__":
    main()
