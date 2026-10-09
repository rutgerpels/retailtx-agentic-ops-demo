"""Local fixed-action safety tests; no Azure resources or service changes."""
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

try:
    import fcntl  # noqa: F401
except ImportError:
    sys.modules["fcntl"] = types.SimpleNamespace(LOCK_EX=2, LOCK_NB=4)

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("guest_controller", ROOT / "scripts" / "guest" / "controller.py")
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
REAL_SYSTEMCTL = controller.systemctl

OWNER = "11111111-1111-1111-1111-111111111111"
ACTOR = "22222222-2222-2222-2222-222222222222"
RUN = "33333333-3333-3333-3333-333333333333"
OTHER = "44444444-4444-4444-4444-444444444444"


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.config = {"schemaVersion": 1, "ownerToken": OWNER,
                       "sourceHashes": {name: "a" * 64 for name in controller.FILES}}
        self.state = {"ownerToken": OWNER, "marker": None, "usedRunIds": [], "watchdogProof": None}
        self.active = True
        self.timer = True
        self.saved = []
        self.calls = []
        self.now = 1000
        self.patches = [
            patch.object(controller.time, "time", lambda: self.now),
            patch.object(controller.time, "monotonic", lambda: self.now),
            patch.object(controller, "boot_id", return_value="boot-original"),
            patch.object(controller, "healthy", lambda: self.active),
            patch.object(controller, "await_health", self.await_health),
            patch.object(controller, "systemctl", self.systemctl),
            patch.object(controller, "save", self.save),
        ]
        for value in self.patches:
            value.start()
            self.addCleanup(value.stop)

    def save(self, state):
        import copy
        self.saved.append(copy.deepcopy(state))

    def await_health(self):
        if not self.active:
            raise ValueError("No health")

    def systemctl(self, action, unit):
        self.calls.append((action, unit))
        if unit == controller.TIMER:
            return self.timer
        if action == "stop":
            self.assertEqual(self.saved[-1]["marker"]["phase"], "prepared")
            self.active = False
            return True
        elif action == "start":
            self.active = True
        return self.active

    def request(self, action="fault", canary=True):
        request = {"action": action, "ownerToken": OWNER, "sourceHashes": self.config["sourceHashes"]}
        if action == "fault":
            duration = 60 if canary else 120
            request.update(runId=RUN, actor=ACTOR, startBeforeUtc=controller.utc(self.now + 90),
                           durationSeconds=duration, canary=canary)
        elif action in ("repair", "reset"):
            request.update(runId=RUN, actor=ACTOR)
        return request

    def execute(self, request):
        controller.execute(request, self.config, self.state)

    def test_marker_persists_before_stop_and_exact_evidence(self):
        request = self.request()
        self.execute(request)
        self.assertFalse(self.active)
        self.assertEqual(self.state["marker"]["phase"], "fault-active")
        for name in ("runId", "actor", "startBeforeUtc"):
            self.assertEqual(self.state["marker"][name], request[name])
        self.assertEqual(self.state["marker"]["deadlineUtc"], controller.utc(1060))
        evidence = controller.evidence(self.config, self.state)
        self.assertFalse(evidence["healthy"])
        self.assertTrue(evidence["watchdogEnabled"])
        self.assertTrue(evidence["watchdogActive"])

    def test_watchdog_deadline_canary_proves_longer_fault(self):
        self.execute(self.request())
        self.now = 1059
        controller.watchdog(self.state)
        self.assertFalse(self.active)
        self.now = 1060
        controller.watchdog(self.state)
        self.assertTrue(self.active)
        self.assertEqual(self.state["watchdogProof"]["runId"], RUN)
        self.assertEqual(self.state["marker"]["recoveredBy"], "watchdog")
        longer = self.request(canary=False)
        longer["runId"] = OTHER
        self.execute(longer)
        self.assertFalse(self.active)

    def test_delivery_delay_does_not_shorten_guest_canary(self):
        request = self.request()
        self.now = 1030
        self.execute(request)
        self.assertEqual(self.state["marker"]["deadlineUtc"], controller.utc(1090))
        self.now = 1060
        controller.watchdog(self.state)
        self.assertFalse(self.active)
        self.now = 1090
        controller.watchdog(self.state)
        self.assertTrue(self.active)

    def test_wall_clock_rollback_cannot_extend_fault(self):
        self.execute(self.request())
        self.now = 1061
        with patch.object(controller.time, "time", return_value=800):
            controller.watchdog(self.state)
        self.assertTrue(self.active)
        self.assertEqual(self.state["watchdogProof"]["runId"], RUN)

    def test_wall_clock_jump_cannot_falsely_prove_minimum_canary(self):
        self.execute(self.request())
        with patch.object(controller.time, "time", return_value=2000):
            controller.watchdog(self.state)
        self.assertTrue(self.active)
        self.assertIsNone(self.state["watchdogProof"])

    def test_late_delivery_is_rejected_without_stop(self):
        request = self.request()
        self.now = 1091
        with self.assertRaises(ValueError):
            self.execute(request)
        self.assertEqual(self.saved, [])
        self.assertNotIn(("stop", controller.SERVICE), self.calls)

    def test_admission_expiring_during_preconditions_cancels_before_stop(self):
        request = self.request()
        original_save = self.save

        def delayed_save(state):
            original_save(state)
            self.now = 1091

        with patch.object(controller, "save", delayed_save):
            with self.assertRaises(ValueError):
                self.execute(request)
        self.assertNotIn(("stop", controller.SERVICE), self.calls)
        self.assertEqual(self.state["marker"]["phase"], "cancelled")
        self.assertEqual(self.saved[-1]["marker"]["cancellationReason"], "admission-expired")
        controller.watchdog(self.state)
        self.assertNotIn(("start", controller.SERVICE), self.calls)
        self.execute(self.request("configure"))
        with self.assertRaises(ValueError):
            self.execute(request)

    def test_longer_fault_requires_canary(self):
        with self.assertRaises(ValueError):
            self.execute(self.request(canary=False))
        self.assertNotIn(("stop", controller.SERVICE), self.calls)

    def test_reboot_recovers_without_falsely_proving_deadline_canary(self):
        self.execute(self.request())
        with patch.object(controller, "boot_id", return_value="new-boot"):
            controller.watchdog(self.state)
        self.assertTrue(self.active)
        self.assertEqual(self.state["marker"]["recoveryReason"], "reboot")
        self.assertIsNone(self.state["watchdogProof"])

    def test_ambiguous_stop_still_has_durable_recovery_marker(self):
        def timed_out(action, unit):
            if action == "stop":
                self.assertEqual(self.saved[-1]["marker"]["phase"], "prepared")
                self.active = False
                raise TimeoutError("Service stop outcome unknown")
            return self.systemctl(action, unit)
        with patch.object(controller, "systemctl", timed_out):
            with self.assertRaises(TimeoutError):
                self.execute(self.request())
        self.assertEqual(self.state["marker"]["phase"], "prepared")
        self.now = 1061
        controller.watchdog(self.state)
        self.assertTrue(self.active)

    def test_no_fault_replay_even_after_reset(self):
        self.execute(self.request())
        self.execute(self.request("reset"))
        self.assertTrue(self.active)
        with self.assertRaises(ValueError):
            self.execute(self.request())
        self.assertEqual(self.state["usedRunIds"], [RUN])

    def test_exact_run_repair_and_actor_evidence(self):
        self.execute(self.request())
        repair = self.request("repair")
        repair["runId"] = OTHER
        with self.assertRaises(ValueError):
            self.execute(repair)
        self.assertFalse(self.active)
        self.execute(self.request("repair"))
        self.assertEqual(self.state["marker"]["recoveredBy"], ACTOR)
        self.assertIsNone(self.state["watchdogProof"])
        self.assertTrue(self.active)

    def test_failed_health_is_not_recovery(self):
        self.execute(self.request())
        with patch.object(controller, "await_health", side_effect=ValueError("failed health")):
            with self.assertRaises(ValueError):
                self.execute(self.request("repair"))
        self.assertEqual(self.state["marker"]["phase"], "recovering")
        self.assertNotIn("recoveredBy", self.state["marker"])
        self.assertIsNone(self.state["watchdogProof"])

    def test_all_inputs_closed_and_bounded(self):
        cases = []
        for key, value in (("ownerToken", OTHER), ("runId", "shell;shutdown"), ("actor", "operator"),
                           ("sourceHashes", {}), ("durationSeconds", 601), ("durationSeconds", True),
                           ("canary", "yes"), ("startBeforeUtc", controller.utc(999)),
                           ("startBeforeUtc", controller.utc(1700))):
            request = self.request()
            request[key] = value
            cases.append(request)
        arbitrary = self.request()
        arbitrary["service"] = "sshd"
        cases.append(arbitrary)
        arbitrary = self.request()
        arbitrary["action"] = "exec"
        cases.append(arbitrary)
        for request in cases:
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.execute(request)
        self.assertNotIn(("stop", controller.SERVICE), self.calls)

    def test_timer_and_health_preconditions(self):
        self.timer = False
        with self.assertRaises(ValueError):
            self.execute(self.request())
        self.timer = True
        self.active = False
        with self.assertRaises(ValueError):
            self.execute(self.request())
        self.assertEqual(self.saved, [])

    def test_pending_fault_blocks_configure_and_second_fault(self):
        self.execute(self.request())
        with self.assertRaises(ValueError):
            self.execute(self.request("configure"))
        other = self.request()
        other["runId"] = OTHER
        with self.assertRaises(ValueError):
            self.execute(other)

    def test_reset_no_marker_requires_empty_run(self):
        reset = self.request("reset")
        with self.assertRaises(ValueError):
            self.execute(reset)
        reset["runId"] = "00000000-0000-0000-0000-000000000000"
        self.execute(reset)
        self.assertTrue(self.active)

    def test_closed_systemctl_argv(self):
        # Test the real helper independently of our simulated fixture.
        with self.assertRaises(ValueError):
            REAL_SYSTEMCTL("stop", "sshd")
        with self.assertRaises(ValueError):
            REAL_SYSTEMCTL("restart", controller.SERVICE)

    def test_history_capacity_blocks_fault_without_erasing_replay_guard(self):
        self.state["usedRunIds"] = [str(index) for index in range(256)]
        with self.assertRaises(ValueError):
            self.execute(self.request())
        self.assertNotIn(("stop", controller.SERVICE), self.calls)

    def test_evidence_fits_provider_output_bound_after_recovery(self):
        import json
        self.execute(self.request())
        self.now = 1061
        controller.watchdog(self.state)
        encoded = "RETAILTX_GUEST=" + json.dumps(controller.evidence(self.config, self.state), separators=(",", ":"))
        self.assertLess(len(encoded.encode()), 3500)


class WorkerTests(unittest.TestCase):
    def test_localhost_health_is_real_and_no_other_routes(self):
        from http.server import HTTPServer
        from threading import Thread
        from urllib.error import HTTPError
        from urllib.request import urlopen
        import json
        worker_spec = importlib.util.spec_from_file_location("guest_worker", ROOT / "scripts" / "guest" / "worker.py")
        worker = importlib.util.module_from_spec(worker_spec)
        worker_spec.loader.exec_module(worker)
        server = HTTPServer(("127.0.0.1", 0), worker.HealthHandler)
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            origin = f"http://127.0.0.1:{server.server_port}"
            with urlopen(origin + "/health", timeout=2) as response:
                self.assertEqual(json.loads(response.read()), {"service": controller.SERVICE, "healthy": True})
            with self.assertRaises(HTTPError):
                urlopen(origin + "/arbitrary", timeout=2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        import base64
        import hashlib
        import json
        bootstrap_spec = importlib.util.spec_from_file_location("guest_bootstrap", ROOT / "scripts" / "guest" / "bootstrap.py")
        self.bootstrap = importlib.util.module_from_spec(bootstrap_spec)
        bootstrap_spec.loader.exec_module(self.bootstrap)
        self.sources = {name: (ROOT / "scripts" / "guest" / name).read_bytes() for name in controller.FILES}
        self.payload = {
            "config": {"schemaVersion": 1, "ownerToken": OWNER, "sourceHashes": {
                name: hashlib.sha256(content).hexdigest() for name, content in self.sources.items()}},
            "sources": {name: base64.b64encode(content).decode() for name, content in self.sources.items()},
        }
        self.encode = lambda: base64.b64encode(json.dumps(self.payload).encode()).decode()

    def test_configure_installs_only_exact_sources_and_fixed_units(self):
        import base64
        import json
        from unittest.mock import Mock
        writes = Mock()
        calls = Mock()
        with patch.object(self.bootstrap.os, "geteuid", return_value=0, create=True), \
                patch.object(self.bootstrap.sys, "argv", ["bootstrap.py", self.encode()]), \
                patch.object(self.bootstrap, "safe_directory"), \
                patch.object(self.bootstrap, "install_exact", writes), \
                patch.object(self.bootstrap.subprocess, "run", calls):
            self.bootstrap.main()
        self.assertEqual(writes.call_count, 7)
        for call in writes.call_args_list[1:]:
            path, content, mode = call.args
            self.assertEqual(content, self.sources[path.name])
            self.assertEqual(mode, 0o644)
        self.assertEqual(calls.call_args_list[0].args[0], ["/usr/bin/systemctl", "daemon-reload"])
        request = json.loads(base64.b64decode(calls.call_args_list[-1].args[0][-1]))
        self.assertEqual(request["action"], "configure")
        self.assertEqual(request["ownerToken"], OWNER)
        self.assertEqual(request["sourceHashes"], self.payload["config"]["sourceHashes"])

    def test_wrong_source_or_foreign_payload_rejected_before_installation(self):
        from unittest.mock import Mock
        self.payload["sources"]["worker.py"] = "bWFsaWNpb3Vz"
        writes = Mock()
        with patch.object(self.bootstrap.os, "geteuid", return_value=0, create=True), \
                patch.object(self.bootstrap.sys, "argv", ["bootstrap.py", self.encode()]), \
                patch.object(self.bootstrap, "install_exact", writes):
            with self.assertRaises(ValueError):
                self.bootstrap.main()
        writes.assert_not_called()
        self.payload["sources"]["foreign.py"] = ""
        with patch.object(self.bootstrap.os, "geteuid", return_value=0, create=True), \
                patch.object(self.bootstrap.sys, "argv", ["bootstrap.py", self.encode()]):
            with self.assertRaises(ValueError):
                self.bootstrap.main()

    def test_existing_installation_cannot_be_replaced_or_adopted(self):
        import stat
        from unittest.mock import Mock
        path = Mock()
        path.exists.return_value = True
        path.lstat.return_value = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o644)
        path.read_bytes.return_value = b"known source"
        self.bootstrap.install_exact(path, b"known source", 0o644)
        with self.assertRaises(ValueError):
            self.bootstrap.install_exact(path, b"replacement", 0o644)
        path.lstat.return_value.st_uid = 1000
        with self.assertRaises(ValueError):
            self.bootstrap.install_exact(path, b"known source", 0o644)
        path.lstat.return_value.st_uid = 0
        path.lstat.return_value.st_mode = stat.S_IFLNK | 0o777
        with self.assertRaises(ValueError):
            self.bootstrap.install_exact(path, b"known source", 0o644)

    def test_controller_rejects_writable_or_symlink_state_paths(self):
        import stat
        from unittest.mock import Mock
        path = Mock()
        path.lstat.return_value = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o600)
        controller.protected(path)
        for mode, owner in ((stat.S_IFREG | 0o666, 0), (stat.S_IFLNK | 0o777, 0),
                            (stat.S_IFREG | 0o600, 1000)):
            path.lstat.return_value = types.SimpleNamespace(st_uid=owner, st_mode=mode)
            with self.assertRaises(ValueError):
                controller.protected(path)


if __name__ == "__main__":
    unittest.main()
