import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import watcher


class WatcherTests(unittest.TestCase):
    def test_unchanged_routes_do_not_trigger_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "challenges.yml"
            watcher.atomic_write(path, "first")
            original_inode = path.stat().st_ino
            watcher.atomic_write(path, "first")
            self.assertEqual(original_inode, path.stat().st_ino)
            watcher.atomic_write(path, "second")
            self.assertEqual(path.read_text(), "second")

    def test_route_appears_when_backend_starts(self):
        listing = [{"Id": "test-instance", "State": "running"}]
        info = {
            "Config": {"Labels": {"PublicHttpRoute": "true", "ChallengeId": "1", "TeamId": "2"}},
            "NetworkSettings": {"Networks": {"challenges-open": {"IPAddress": "127.0.0.1"}},
                                "Ports": {"5000/tcp": [{"HostPort": "32000"}]}},
            "Name": "/readiness-test",
        }
        with patch.object(watcher, "docker_get", side_effect=lambda path: listing if path.startswith("/containers/json?") else info):
            with patch.object(watcher, "is_http_service", return_value=False):
                config, routes = watcher.build_routes()
                self.assertEqual(config["http"]["routers"], {})
                self.assertFalse(routes[0]["proxied"])
            with patch.object(watcher, "is_http_service", return_value=True):
                config, routes = watcher.build_routes()
                self.assertEqual(len(config["http"]["routers"]), 1)
                self.assertTrue(routes[0]["proxied"])


if __name__ == "__main__":
    unittest.main()
