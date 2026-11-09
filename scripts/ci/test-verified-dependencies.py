import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("deps", Path(__file__).with_name("verified-dependencies.py"))
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)


class VerificationTest(unittest.TestCase):
    def test_wrong_bytes_never_become_accepted_or_replace_corrupt_cache(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "chart.tgz"
            verify = lambda body: deps.verify_digest(body, deps.sha(b"good"), "chart")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                deps.checked_input(path, lambda: b"bad", verify)
            self.assertFalse(path.exists())
            path.write_bytes(b"bad")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                deps.checked_input(path, lambda: b"good", verify)
            self.assertEqual(path.read_bytes(), b"bad")

    def test_hash_must_belong_to_the_matching_locked_provider(self):
        digest = deps.sha(b"good")
        lock = ('provider "registry.terraform.io/vercel/vercel" {\n  version = "5.26.1"\n}\n'
                'provider "registry.terraform.io/contabo/contabo" {\n'
                '  version = "0.1.44"\n  hashes = ["zh:' + digest + '"]\n}\n')
        with self.assertRaisesRegex(ValueError, "absent"):
            deps.verify_lock(lock, "vercel", "5.26.1", digest)
        deps.verify_lock(lock, "contabo", "0.1.44", digest)

    def test_changed_upstream_versions_use_the_normal_fetcher(self):
        with tempfile.TemporaryDirectory() as work, mock.patch.object(deps, "fetch", side_effect=AssertionError("download")):
            root = Path(work)
            cache = root / "out"
            lock = root / "infisical/terraform/.terraform.lock.hcl"
            lock.parent.mkdir(parents=True)
            lock.write_text('provider "registry.terraform.io/infisical/infisical" {\n  version = "2.0.0"\n}')
            self.assertFalse(deps.provider(root, cache, root / "mirror", "infisical"))
            path = root / "gitops/applications/metrics-server.yaml"
            path.parent.mkdir(parents=True)
            path.write_text('    - repoURL: https://kubernetes-sigs.github.io/metrics-server/\n'
                            '      chart: metrics-server\n      targetRevision: 9.0.0\n')
            deps.chart(root, cache, root / "usable", "metrics-server")
            self.assertFalse(cache.exists())

    def test_reads_the_terraform_argo_source_before_using_an_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "infrastructure/terraform/modules/argocd/main.tf"
            path.parent.mkdir(parents=True)
            path.write_text('resource "helm_release" "argocd" {\n  repository = "https://argoproj.github.io/argo-helm"\n'
                            '  chart = "argo-cd"\n  version = "10.11.7"\n}\n')
            self.assertTrue(deps.wanted_chart(root, "argo-cd", "10.11.7", "https://argoproj.github.io/argo-helm"))
            self.assertFalse(deps.wanted_chart(root, "argo-cd", "10.11.8", "https://argoproj.github.io/argo-helm"))
            self.assertFalse(deps.wanted_chart(root, "argo-cd", "10.11.7", "https://unrelated.invalid"))

    def test_different_versions_in_two_roots_keep_the_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for where, version in [("infisical/terraform", "0.20.10"), ("infrastructure/terraform/environments/new", "0.21.0")]:
                lock = root / where / ".terraform.lock.hcl"
                lock.parent.mkdir(parents=True)
                lock.write_text(f'provider "registry.terraform.io/infisical/infisical" {{\n  version = "{version}"\n}}\n')
            self.assertFalse(deps.provider(root, root / "cache", root / "mirror", "infisical"))

    def test_reject_other_hosts_and_plaintext(self):
        for url in ["http://github.com/asset", "https://untrusted.invalid/",
                    "https://github.com.evil.invalid/", "https://token@api.github.com/asset"]:
            with self.assertRaises(ValueError):
                deps.trusted_url(url)


if __name__ == "__main__":
    unittest.main()
