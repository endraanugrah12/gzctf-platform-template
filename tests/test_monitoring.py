"""Configuration tests only: never starts or modifies application services."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MonitoringTests(unittest.TestCase):
    def test_dashboard_has_provisioned_datasource_and_unique_panels(self):
        dashboard = json.loads((ROOT / "monitoring/grafana/dashboards/system.json").read_text())
        self.assertEqual(dashboard["uid"], "gzctf-system")
        panels = dashboard["panels"]
        self.assertEqual(len({p["id"] for p in panels}), len(panels))
        self.assertGreaterEqual(len(panels), 20)
        for panel in panels:
            self.assertEqual(panel["datasource"]["uid"], "prometheus")
            self.assertTrue(panel["targets"][0]["expr"])

    def test_initializer_private_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "monitoring").mkdir()
            script = root / "scripts/monitoring-init.sh"
            shutil.copyfile(ROOT / "scripts/monitoring-init.sh", script)
            subprocess.run(["sh", str(script)], check=True, capture_output=True)
            env = root / "monitoring/.env"
            original = env.read_bytes()
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            self.assertRegex(original.decode(), r"^GRAFANA_ADMIN_PASSWORD=[0-9a-f]{48}\n$")
            subprocess.run(["sh", str(script)], check=True, capture_output=True)
            self.assertEqual(env.read_bytes(), original)

    def test_compose_is_private_and_independent(self):
        result = subprocess.run(
            ["docker", "compose", "-f", str(ROOT / "monitoring/compose.yml"), "config", "--format", "json"],
            env={**os.environ, "GRAFANA_ADMIN_PASSWORD": "test-only-placeholder"},
            capture_output=True, text=True, check=True,
        )
        config = json.loads(result.stdout)
        self.assertEqual(set(config["services"]), {"prometheus", "grafana", "node-exporter", "cadvisor"})
        for service in config["services"].values():
            self.assertEqual(service["network_mode"], "host")
            self.assertNotIn("ports", service)
            self.assertNotIn("privileged", service)
            self.assertNotIn(":latest", service["image"])
        services = config["services"]
        self.assertEqual(services["grafana"]["environment"]["GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH"], "/etc/grafana/dashboards/system.json")
        self.assertEqual(services["grafana"]["environment"]["GF_SERVER_HTTP_ADDR"], "127.0.0.1")
        self.assertIn("--web.listen-address=127.0.0.1:19090", services["prometheus"]["command"])
        self.assertIn("--web.listen-address=127.0.0.1:19100", services["node-exporter"]["command"])
        self.assertIn("--listen_ip=127.0.0.1", services["cadvisor"]["command"])


if __name__ == "__main__":
    unittest.main()
