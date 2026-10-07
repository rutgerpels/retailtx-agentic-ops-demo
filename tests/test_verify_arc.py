"""Offline checks for the fixed Arc identity/telemetry verifier."""

import importlib.util
import io
from pathlib import Path
import unittest
import urllib.error
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "verify_arc", Path(__file__).parents[1] / "scripts" / "verify-arc.py"
)
verify_arc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_arc)
WORKSPACE = "11111111-1111-1111-1111-111111111111"
MACHINE = (
    f"/subscriptions/{WORKSPACE}/resourceGroups/rg-retailtx-test-swedencentral"
    "/providers/Microsoft.HybridCompute/machines/erp-core-01"
)


class ArcVerifierTests(unittest.TestCase):
    def test_installer_runs_after_bootstrap_token_and_imds_block(self):
        source = (Path(__file__).parents[1] / "scripts" / "bootstrap-arc.sh").read_text()
        token = source.index("token=$(curl")
        block = source.index("systemctl enable --now retailtx-block-imds.service")
        install = source.index('bash "$installer"')
        self.assertLess(token, block)
        self.assertLess(block, install)
        self.assertLess(source.index("systemctl disable --now walinuxagent"), install)

    def test_invalid_workspace_rejected_before_host_commands(self):
        with patch.object(verify_arc.subprocess, "run") as command:
            with self.assertRaises(ValueError):
                verify_arc.verify("../another-workspace", MACHINE)
            command.assert_not_called()

    def test_public_dns_rejected_before_token_acquisition(self):
        with (
            patch.object(verify_arc.subprocess, "run"),
            patch.object(verify_arc.Path, "is_file", return_value=True),
            patch.object(
                verify_arc.socket, "getaddrinfo",
                return_value=[(2, 1, 6, "", ("8.8.8.8", 443))],
            ),
            patch.object(verify_arc, "get_arc_token") as token,
        ):
            with self.assertRaisesRegex(RuntimeError, "private addresses"):
                verify_arc.verify(WORKSPACE, MACHINE)
            token.assert_not_called()

    def test_challenge_cannot_read_arbitrary_file(self):
        error = urllib.error.HTTPError(
            "http://127.0.0.1", 401, "challenge",
            {"WWW-Authenticate": "Basic realm=/etc/shadow"}, None,
        )
        with patch.object(verify_arc.urllib.request, "build_opener") as factory:
            factory.return_value.open.side_effect = error
            with self.assertRaisesRegex(RuntimeError, "outside the token directory"):
                verify_arc.get_arc_token("https://api.loganalytics.io")

    def test_non_challenge_error_propagates(self):
        error = urllib.error.HTTPError("http://127.0.0.1", 503, "Unavailable", {}, None)
        with patch.object(verify_arc.urllib.request, "build_opener") as factory:
            factory.return_value.open.side_effect = error
            with self.assertRaises(urllib.error.HTTPError):
                verify_arc.get_arc_token("https://api.loganalytics.io")

    def test_empty_telemetry_is_not_success(self):
        with (
            patch.object(verify_arc.subprocess, "run"),
            patch.object(verify_arc.Path, "is_file", return_value=True),
            patch.object(
                verify_arc.socket, "getaddrinfo",
                return_value=[(2, 1, 6, "", ("10.84.1.4", 443))],
            ),
            patch.object(verify_arc, "get_arc_token", return_value="test-token"),
            patch.object(
                verify_arc.urllib.request, "urlopen",
                return_value=io.BytesIO(b'{"tables":[{"rows":[]}]}'),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "No recent AMA heartbeat"):
                verify_arc.verify(WORKSPACE, MACHINE)

    def test_public_query_dns_rejected_before_token_acquisition(self):
        with (
            patch.object(verify_arc.subprocess, "run"),
            patch.object(verify_arc.Path, "is_file", return_value=True),
            patch.object(
                verify_arc.socket, "getaddrinfo",
                side_effect=[
                    [(2, 1, 6, "", ("10.84.1.4", 443))],
                    [(2, 1, 6, "", ("8.8.8.8", 443))],
                ],
            ),
            patch.object(verify_arc, "get_arc_token") as token,
        ):
            with self.assertRaisesRegex(RuntimeError, "api.loganalytics.io"):
                verify_arc.verify(WORKSPACE, MACHINE)
            token.assert_not_called()

    def test_machine_id_injection_rejected(self):
        with patch.object(verify_arc.subprocess, "run") as command:
            with self.assertRaises(ValueError):
                verify_arc.verify(WORKSPACE, MACHINE + "' | union Heartbeat")
            command.assert_not_called()

    def test_success_queries_only_the_expected_machine(self):
        with (
            patch.object(verify_arc.subprocess, "run"),
            patch.object(verify_arc.Path, "is_file", return_value=True),
            patch.object(
                verify_arc.socket, "getaddrinfo",
                return_value=[(2, 1, 6, "", ("10.84.1.4", 443))],
            ),
            patch.object(verify_arc, "get_arc_token", return_value="test-token"),
            patch.object(
                verify_arc.urllib.request, "urlopen",
                return_value=io.BytesIO(b'{"tables":[{"rows":[["erp-core-01","now"]]}]}'),
            ) as query,
        ):
            evidence = verify_arc.verify(WORKSPACE, MACHINE)
            self.assertEqual(evidence["machineId"], MACHINE)
            self.assertTrue(evidence["recentHeartbeat"])
            self.assertIn(f"where _ResourceId =~ '{MACHINE}'", query.call_args.args[0].data.decode())


if __name__ == "__main__":
    unittest.main()
