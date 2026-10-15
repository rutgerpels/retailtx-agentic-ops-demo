"""Mocked submit-once Bicep orchestration; no Azure calls or resource PUTs."""

import copy
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts.github import federation, intake

LOCATION = "swedencentral"
EXPIRY = "2030-01-01T00:00:00Z"
PRINCIPAL = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
CLIENT = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
TENANT = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
REPOSITORY = {
    "full_name": "rutgerpels/retailtx-agentic-ops-demo",
    "id": 1399486000,
    "owner": {"login": "rutgerpels", "id": 121695274},
}
TEMPLATE = {
    "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "metadata": {"_generator": {"templateHash": "123456789"}},
    "resources": [],
}


class Arm:
    def __init__(self):
        self.assets = {}
        self.calls = []
        self.error = None

    def request(self, method, path, body=None):
        self.calls.append((method, path))
        if self.error:
            raise self.error
        if method == "GET":
            return (200, copy.deepcopy(self.assets[path])) if path in self.assets else (404, None)
        if method == "DELETE":
            del self.assets[path]
            return 204, None
        pytest.fail(f"Python must not issue {method} for Bicep resource creation")


class Runner:
    def __init__(self, config, state_path, api):
        self.config = config
        self.state_path = state_path
        self.api = api
        self.calls = []
        self.create_assets = True
        self.create_receipt = True
        self.status = "Succeeded"
        self.outcome = "success"
        self.build_outcome = "success"
        self.after_build = None
        self.after_deploy = None
        self.template = copy.deepcopy(TEMPLATE)
        self.temporary_paths = []

    def install(self, kinds=None):
        plan = federation.bicep_spec(self.config, LOCATION, EXPIRY)
        deployment = plan["deployment"]
        if self.create_receipt:
            self.api.assets[federation.deployment_path(deployment)] = {
                "id": deployment["id"],
                "location": LOCATION,
                "properties": {
                    "mode": "Incremental",
                    "provisioningState": self.status,
                    "templateHash": self.template["metadata"]["_generator"]["templateHash"],
                    "parameters": {
                        key: {**value, "type": "String"}
                        for key, value in deployment["parameters"].items()
                    },
                },
            }
        if self.create_assets:
            for asset in plan["assets"]:
                if kinds is not None and asset["kind"] not in kinds:
                    continue
                body = copy.deepcopy(asset["body"])
                if asset["kind"] == "identity":
                    body["properties"] = {
                        "clientId": CLIENT,
                        "principalId": PRINCIPAL,
                        "tenantId": TENANT,
                    }
                elif asset["kind"] == "assignment":
                    body["properties"]["principalId"] = PRINCIPAL
                self.api.assets[federation.resource_path(asset)] = {"id": asset["id"], **body}

    def __call__(self, arguments, **options):
        self.calls.append((arguments, options))
        assert arguments[0] == "absolute-az.cmd"
        assert options["shell"] is False and options["check"] is False
        assert options["capture_output"] is True and options["text"] is True
        state = json.loads(self.state_path.read_text())
        assert state["phase"] == "BicepDeploymentRequested"
        assert [asset["phase"] for asset in state["assets"]] == ["Requested"] * 4
        assert state["configHash"] == federation.binding_hash(self.config)
        assert state["roleProfile"] == federation.ROLE_PROFILE
        assert "clientId" not in state and "principalId" not in state
        if arguments[1:3] == ["bicep", "build"]:
            assert options["timeout"] == 120
            assert "--stdout" in arguments and "--no-restore" in arguments
            assert state["bicepDeployment"]["submissionOutcome"] == "NotSubmitted"
            if self.after_build:
                self.after_build()
            if self.build_outcome == "timeout":
                raise subprocess.TimeoutExpired(arguments, 120)
            return SimpleNamespace(
                returncode=1 if self.build_outcome == "failure" else 0,
                stdout="not-json"
                if self.build_outcome == "invalid-json"
                else json.dumps(self.template),
            )
        assert arguments[1:4] == ["deployment", "sub", "create"]
        assert options["timeout"] == 600
        assert state["bicepDeployment"]["submissionOutcome"] == "Unknown"
        assert state["bicepDeployment"]["templateHash"] == "123456789"
        assert state["bicepDeployment"]["compiledTemplateSha256"] == intake.digest(self.template)
        assert (
            arguments[arguments.index("--subscription") + 1]
            == self.config["binding"]["subscriptionId"]
        )
        assert arguments[arguments.index("--name") + 1] == state["bicepDeployment"]["name"]
        assert arguments[arguments.index("--location") + 1] == LOCATION
        template_path = Path(arguments[arguments.index("--template-file") + 1])
        parameters_path = Path(arguments[arguments.index("--parameters") + 1][1:])
        self.temporary_paths.extend([template_path, parameters_path])
        assert json.loads(template_path.read_text()) == self.template
        assert (
            json.loads(parameters_path.read_text())["parameters"]
            == state["bicepDeployment"]["parameters"]
        )
        assert all(method == "GET" for method, _ in self.api.calls)
        assert len(self.api.calls) == 10  # Two full five-path absence preflights.
        self.install()
        if self.after_deploy:
            self.after_deploy()
        if self.outcome == "timeout":
            raise subprocess.TimeoutExpired(arguments, 600)
        if self.outcome == "oserror":
            raise OSError("lost invocation outcome")
        if self.outcome == "crash":
            raise SystemExit("crash after submission")
        return SimpleNamespace(
            returncode=int(self.outcome == "failure"), stdout="never trust CLI outputs"
        )


@pytest.fixture
def setup(tmp_path, monkeypatch):
    config = json.loads((intake.ROOT / "profiles/github/intake.example.json").read_text())
    api = Arm()
    path = tmp_path / "federation.json"
    runner = Runner(config, path, api)
    monkeypatch.setattr(federation, "azure_cli_executable", lambda: "absolute-az.cmd")
    monkeypatch.setattr(federation.subprocess, "run", runner)
    monkeypatch.setattr(federation, "BICEP_READBACK_SECONDS", 0)
    return config, path, api, runner


def deploy(setup, **overrides):
    config, path, api, _ = setup
    return federation.deploy_bicep(
        config,
        path,
        api,
        overrides.get("location", LOCATION),
        overrides.get("expires_at", EXPIRY),
        overrides.get("repository_evidence", REPOSITORY),
    )


def test_success_readback_repeat_check_and_inverse_teardown(setup):
    config, path, api, runner = setup
    state = deploy(setup)
    assert state["schemaVersion"] == 1
    assert state["phase"] == "ConfiguredOidcUnverified"
    assert state["bicepDeployment"]["phase"] == "Verified"
    assert state["bicepDeployment"]["submissionOutcome"] == "ReturnedSuccess"
    assert {key: state[key] for key in ("clientId", "principalId", "tenantId")} == {
        "clientId": CLIENT,
        "principalId": PRINCIPAL,
        "tenantId": TENANT,
    }
    assert all(asset["phase"] == "Verified" for asset in state["assets"])
    assert state["assets"][-1]["body"]["properties"]["principalId"] == PRINCIPAL
    assert "runtimeVerified" not in state and "knowledgeRetrievalVerified" not in state
    federation.manifest_value(config, state)
    deploy(setup)
    federation.check(config, path, api)
    assert len(runner.calls) == 2
    assert all(not temporary.exists() for temporary in runner.temporary_paths)
    with pytest.raises(ValueError, match="Bicep-owned"):
        federation.configure(config, path, api, LOCATION, EXPIRY, REPOSITORY)
    federation.remove(config, path, api)
    deleted = [resource for method, resource in api.calls if method == "DELETE"]
    assert deleted == [federation.resource_path(asset) for asset in reversed(state["assets"])]
    assert json.loads(path.read_text())["phase"] == "Removed"
    with pytest.raises(ValueError, match="recreation"):
        deploy(setup)
    assert len(runner.calls) == 2


@pytest.mark.parametrize("outcome", ["failure", "timeout", "oserror"])
def test_lost_or_nonzero_response_can_reconcile_success_without_replay(setup, outcome):
    _, path, api, runner = setup
    runner.outcome = outcome
    state = deploy(setup)
    assert state["phase"] == "ConfiguredOidcUnverified"
    assert state["bicepDeployment"]["submissionOutcome"] == (
        "ReturnedFailure" if outcome == "failure" else "Unknown"
    )
    assert all(method == "GET" for method, _ in api.calls)
    assert deploy(setup) == json.loads(path.read_text())
    assert len(runner.calls) == 2


@pytest.mark.parametrize("outcome", ["success", "failure", "timeout", "oserror"])
def test_absent_or_uncertain_creation_never_replays_and_blocks_legacy_paths(setup, outcome):
    config, path, api, runner = setup
    runner.outcome = outcome
    runner.create_assets = runner.create_receipt = False
    with pytest.raises(RuntimeError, match="never replay"):
        deploy(setup)
    state = json.loads(path.read_text())
    assert state["phase"] == "BicepDeploymentRequested"
    assert all(asset["phase"] == "Requested" for asset in state["assets"])
    saved = path.read_bytes()
    for _ in range(2):
        with pytest.raises(RuntimeError, match="never replay"):
            deploy(setup)
    with pytest.raises(ValueError, match="incomplete"):
        federation.check(config, path, api)
    with pytest.raises(ValueError, match="Bicep-owned"):
        federation.configure(config, path, api, LOCATION, EXPIRY, REPOSITORY)
    with pytest.raises(ValueError, match="reconcile deploy-bicep"):
        federation.remove(config, path, api)
    assert path.read_bytes() == saved
    assert len(runner.calls) == 2
    assert all(method == "GET" for method, _ in api.calls)


def test_crash_after_submission_is_reconciled_get_only(setup):
    _, path, _, runner = setup
    runner.outcome = "crash"
    with pytest.raises(SystemExit):
        deploy(setup)
    assert json.loads(path.read_text())["bicepDeployment"]["submissionOutcome"] == "Unknown"
    assert deploy(setup)["phase"] == "ConfiguredOidcUnverified"
    assert len(runner.calls) == 2


@pytest.mark.parametrize("kind", ["identity", "federation", "role", "assignment", "deployment"])
def test_all_unowned_collisions_block_first_deploy_without_state(setup, kind):
    config, path, api, runner = setup
    plan = federation.bicep_spec(config, LOCATION, EXPIRY)
    if kind == "deployment":
        collision = federation.deployment_path(plan["deployment"])
    else:
        collision = federation.resource_path(
            next(asset for asset in plan["assets"] if asset["kind"] == kind)
        )
    api.assets[collision] = {"id": collision.split("?")[0]}
    with pytest.raises(ValueError, match="collision"):
        deploy(setup)
    assert len(api.calls) == 5
    assert not runner.calls and not path.exists()


def test_late_exact_shape_collision_before_submit_is_not_adopted(setup):
    _, path, api, runner = setup
    runner.after_build = lambda: runner.install(kinds=["identity"])
    with pytest.raises(ValueError, match="collision"):
        deploy(setup)
    assert len(runner.calls) == 1
    assert json.loads(path.read_text())["bicepDeployment"]["submissionOutcome"] == "NotSubmitted"
    # Even an exact matching receipt is not proof of a submission we did not journal.
    with pytest.raises(RuntimeError, match="not journaled"):
        deploy(setup)
    assert len(runner.calls) == 1
    assert all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("build_outcome", ["failure", "timeout", "invalid-json", "missing-hash"])
def test_local_compile_failure_keeps_intent_and_no_submission(setup, build_outcome):
    _, path, _, runner = setup
    runner.build_outcome = build_outcome
    if build_outcome == "missing-hash":
        runner.template["metadata"]["_generator"].pop("templateHash")
    with pytest.raises((RuntimeError, subprocess.TimeoutExpired, ValueError)):
        deploy(setup)
    assert json.loads(path.read_text())["bicepDeployment"]["submissionOutcome"] == "NotSubmitted"
    with pytest.raises(RuntimeError, match="not journaled"):
        deploy(setup)
    assert len(runner.calls) == 1


def test_source_change_during_compile_blocks_submission(setup, tmp_path, monkeypatch):
    _, _, _, runner = setup
    source = tmp_path / "module.bicep"
    source.write_text("before")
    monkeypatch.setattr(federation, "BICEP_MODULE", source)
    runner.after_build = lambda: source.write_text("after")
    with pytest.raises(ValueError, match="source changed"):
        deploy(setup)
    assert len(runner.calls) == 1


def test_partial_creation_pins_principal_and_later_reconciles_without_cli(setup):
    config, path, api, runner = setup
    runner.create_assets = False
    runner.status = "Running"

    def partial():
        runner.create_assets = True
        runner.install(kinds=["identity", "role"])

    runner.after_deploy = partial
    with pytest.raises(RuntimeError, match="never replay"):
        deploy(setup)
    state = json.loads(path.read_text())
    assert state["principalId"] == PRINCIPAL
    assert [asset["phase"] for asset in state["assets"]] == [
        "Verified",
        "Requested",
        "Verified",
        "Requested",
    ]
    assert state["phase"] == "BicepDeploymentRequested"
    runner.status = "Succeeded"
    runner.install()
    assert deploy(setup)["phase"] == "ConfiguredOidcUnverified"
    assert len(runner.calls) == 2
    federation.check(config, path, api)


@pytest.mark.parametrize("status", ["Failed", "Canceled"])
def test_failed_deployment_cannot_be_ready_even_with_four_matching_assets(setup, status):
    _, path, _, runner = setup
    runner.status = status
    with pytest.raises(RuntimeError, match=status):
        deploy(setup)
    assert json.loads(path.read_text())["phase"] == "BicepDeploymentRequested"
    with pytest.raises(RuntimeError, match=status):
        deploy(setup)
    assert len(runner.calls) == 2


def test_matching_assets_without_frozen_receipt_are_not_adopted(setup):
    _, path, _, runner = setup
    runner.create_receipt = False
    with pytest.raises(RuntimeError, match="never replay"):
        deploy(setup)
    state = json.loads(path.read_text())
    assert "principalId" not in state
    assert all(asset["phase"] == "Requested" for asset in state["assets"])


@pytest.mark.parametrize(
    "field", ["id", "location", "mode", "parameters", "templateHash", "provisioningState"]
)
def test_receipt_drift_blocks_all_adoption(setup, field):
    config, path, api, runner = setup

    def drift():
        receipt = api.assets[
            federation.deployment_path(
                federation.bicep_spec(config, LOCATION, EXPIRY)["deployment"]
            )
        ]
        if field in ("id", "location"):
            receipt[field] = "foreign"
        elif field == "parameters":
            receipt["properties"][field]["agentId"]["value"] += "-foreign"
        else:
            receipt["properties"][field] = "foreign"

    runner.after_deploy = drift
    with pytest.raises(ValueError, match="receipt"):
        deploy(setup)
    assert "principalId" not in json.loads(path.read_text())
    with pytest.raises(ValueError, match="receipt"):
        deploy(setup)
    assert len(runner.calls) == 2


@pytest.mark.parametrize("kind", ["identity", "federation", "role", "assignment"])
def test_asset_drift_is_rejected_without_replay(setup, kind):
    config, path, api, runner = setup

    def drift():
        asset = next(
            asset
            for asset in federation.bicep_spec(config, LOCATION, EXPIRY)["assets"]
            if asset["kind"] == kind
        )
        live = api.assets[federation.resource_path(asset)]
        if kind == "identity":
            live["tags"]["ownerToken"] = "foreign"
        elif kind == "federation":
            live["properties"]["subject"] = "repo:*:environment:sre-github-intake"
        elif kind == "role":
            live["properties"]["permissions"][0]["dataActions"].append(
                "Microsoft.App/agents/threads/approve/action"
            )
        else:
            live["properties"]["principalId"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"

    runner.after_deploy = drift
    with pytest.raises(ValueError, match="drift"):
        deploy(setup)
    assert json.loads(path.read_text())["phase"] == "BicepDeploymentRequested"
    with pytest.raises(ValueError, match="drift"):
        deploy(setup)
    assert len(runner.calls) == 2


@pytest.mark.parametrize("field", ["clientId", "principalId", "tenantId"])
def test_replacement_of_pinned_identity_is_not_adopted(setup, field):
    config, path, api, runner = setup
    state = deploy(setup)
    saved = path.read_bytes()
    live = api.assets[federation.resource_path(state["assets"][0])]
    live["properties"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    with pytest.raises(ValueError, match="changed"):
        deploy(setup)
    assert path.read_bytes() == saved and len(runner.calls) == 2
    with pytest.raises(ValueError, match="changed"):
        federation.remove(config, path, api)


@pytest.mark.parametrize(
    "override", [{"location": "westeurope"}, {"expires_at": "2031-01-01T00:00:00Z"}]
)
def test_frozen_inputs_cannot_be_changed_on_repeat(setup, override):
    _, path, _, runner = setup
    deploy(setup)
    saved = path.read_bytes()
    with pytest.raises(ValueError, match="intent changed"):
        deploy(setup, **override)
    assert path.read_bytes() == saved and len(runner.calls) == 2


@pytest.mark.parametrize("evidence", [None, {**REPOSITORY, "id": 1}])
def test_unverified_repository_binding_rejected_before_cli_or_get(setup, evidence):
    _, path, api, runner = setup
    with pytest.raises(ValueError):
        deploy(setup, repository_evidence=evidence)
    assert not path.exists() and not runner.calls and not api.calls


def test_preflight_read_failure_cannot_claim_absence(setup):
    _, path, api, runner = setup
    api.error = TimeoutError("unknown GET")
    with pytest.raises(TimeoutError):
        deploy(setup)
    assert not path.exists() and not runner.calls


def test_first_intent_persistence_failure_blocks_all_cli_calls(setup, monkeypatch):
    _, path, _, runner = setup

    def fail(*args):
        raise OSError("no durable storage")

    monkeypatch.setattr(federation, "persist", fail)
    with pytest.raises(OSError):
        deploy(setup)
    assert not path.exists() and not runner.calls


def test_legacy_manifest_cannot_adopt_bicep_deployment(setup):
    config, path, _, runner = setup
    federation.persist(
        path,
        {
            "schemaVersion": 1,
            "ownerToken": config["binding"]["ownerToken"],
            "configHash": federation.binding_hash(config),
            "roleProfile": federation.ROLE_PROFILE,
            "assets": federation.specifications(config, LOCATION, EXPIRY),
            "phase": "ConfiguredOidcUnverified",
        },
    )
    with pytest.raises(ValueError, match="no adoption"):
        deploy(setup)
    assert not runner.calls


def test_bicep_spec_cli_is_pure_and_provides_exact_uuid_parameters(
    setup, tmp_path, monkeypatch, capsys
):
    config, _, api, runner = setup
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(config))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "federation",
            "bicep-spec",
            "--config",
            str(config_path),
            "--location",
            LOCATION,
            "--expires-at",
            EXPIRY,
        ],
    )
    monkeypatch.setattr(federation, "arm_token", lambda _: pytest.fail("pure spec acquired token"))
    federation.main()
    plan = json.loads(capsys.readouterr().out)
    assert plan == federation.bicep_spec(config, LOCATION, EXPIRY)
    assert plan["assets"] == federation.specifications(config, LOCATION, EXPIRY)
    params = plan["deployment"]["parameters"]
    assert params["roleDefinitionName"]["value"] == plan["assets"][2]["id"].rsplit("/", 1)[1]
    assert params["roleAssignmentName"]["value"] == plan["assets"][3]["id"].rsplit("/", 1)[1]
    assert not runner.calls and not api.calls


def test_deploy_cli_dispatches_under_existing_lock_and_releases_it(setup, tmp_path, monkeypatch):
    config, path, api, runner = setup
    config_path = tmp_path / "config.json"
    evidence_path = tmp_path / "repository.json"
    config_path.write_text(json.dumps(config))
    evidence_path.write_text(json.dumps(REPOSITORY))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "federation",
            "deploy-bicep",
            "--config",
            str(config_path),
            "--state",
            str(path),
            "--repository-evidence",
            str(evidence_path),
            "--location",
            LOCATION,
            "--expires-at",
            EXPIRY,
        ],
    )
    monkeypatch.setattr(federation, "arm_token", lambda _: "fake-arm-token")
    monkeypatch.setattr(federation, "Api", lambda origin, token: api)
    runner.after_build = lambda: (
        pytest.fail("lock missing") if not path.with_suffix(".lock").exists() else None
    )
    federation.main()
    assert json.loads(path.read_text())["phase"] == "ConfiguredOidcUnverified"
    assert not path.with_suffix(".lock").exists()
    federation.main()  # Second CLI invocation authenticates for GET, never redeploys.
    assert len(runner.calls) == 2


@pytest.mark.parametrize(
    "missing", ["--location", "--expires-at", "--state", "--repository-evidence"]
)
def test_deploy_cli_requires_trusted_inputs_before_authentication(
    setup, tmp_path, monkeypatch, missing
):
    config, path, _, runner = setup
    config_path = tmp_path / "config.json"
    evidence_path = tmp_path / "repository.json"
    config_path.write_text(json.dumps(config))
    evidence_path.write_text(json.dumps(REPOSITORY))
    args = [
        "federation",
        "deploy-bicep",
        "--config",
        str(config_path),
        "--state",
        str(path),
        "--repository-evidence",
        str(evidence_path),
        "--location",
        LOCATION,
        "--expires-at",
        EXPIRY,
    ]
    index = args.index(missing)
    del args[index : index + 2]
    monkeypatch.setattr(sys, "argv", args)
    monkeypatch.setattr(
        federation, "arm_token", lambda _: pytest.fail("invalid input acquired token")
    )
    with pytest.raises(ValueError):
        federation.main()
    assert not runner.calls and not path.exists()


def test_polling_running_deployment_and_assets_is_get_only(setup, monkeypatch):
    _, _, api, runner = setup
    runner.status = "Running"
    runner.create_assets = False
    monkeypatch.setattr(federation, "BICEP_READBACK_SECONDS", 5)
    monkeypatch.setattr(federation.time, "monotonic", lambda: 0)
    waits = []

    def advance(seconds):
        waits.append(seconds)
        runner.status = "Succeeded"
        runner.create_assets = True
        runner.install()

    monkeypatch.setattr(federation.time, "sleep", advance)
    assert deploy(setup)["phase"] == "ConfiguredOidcUnverified"
    assert waits == [2] and len(runner.calls) == 2
    assert all(method == "GET" for method, _ in api.calls)


def test_pending_placeholder_exception_cannot_fake_a_verified_assignment(setup):
    config, path, _, runner = setup
    runner.create_assets = runner.create_receipt = False
    with pytest.raises(RuntimeError):
        deploy(setup)
    state = json.loads(path.read_text())
    federation.manifest_value(config, state)  # Exact wholly unbound Requested is valid.
    for mutation in (
        "verified-assignment",
        "verified-identity",
        "partial-binding",
        "no-receipt-intent",
    ):
        changed = copy.deepcopy(state)
        if mutation == "verified-assignment":
            changed["assets"][-1]["phase"] = "Verified"
        elif mutation == "verified-identity":
            changed["assets"][0]["phase"] = "Verified"
        elif mutation == "partial-binding":
            changed["clientId"] = CLIENT
        else:
            changed.pop("bicepDeployment")
        with pytest.raises(ValueError, match="principal changed"):
            federation.manifest_value(config, changed)


def test_reconciliation_needs_neither_source_nor_cli_binary(setup, monkeypatch):
    _, _, _, runner = setup
    deploy(setup)
    monkeypatch.setattr(federation, "BICEP_MODULE", Path("does-not-exist.bicep"))
    monkeypatch.setattr(
        federation, "azure_cli_executable", lambda: pytest.fail("retry resolved CLI")
    )
    assert deploy(setup)["phase"] == "ConfiguredOidcUnverified"
    assert len(runner.calls) == 2


def test_wal_persistence_failure_before_submit_cannot_deploy(setup, monkeypatch):
    _, path, api, runner = setup
    real_persist = federation.persist

    def save(destination, state):
        if (
            destination == path
            and state.get("bicepDeployment", {}).get("submissionOutcome") == "Unknown"
        ):
            raise OSError("submission WAL not durable")
        real_persist(destination, state)

    monkeypatch.setattr(federation, "persist", save)
    with pytest.raises(OSError, match="WAL"):
        deploy(setup)
    assert len(runner.calls) == 1
    assert json.loads(path.read_text())["bicepDeployment"]["submissionOutcome"] == "NotSubmitted"
    with pytest.raises(RuntimeError, match="not journaled"):
        deploy(setup)
    assert len(runner.calls) == 1 and all(method == "GET" for method, _ in api.calls)


def test_result_journaling_failure_still_reconciles_unknown_wal(setup, monkeypatch):
    _, path, _, runner = setup
    real_persist = federation.persist
    failed = False

    def save(destination, state):
        nonlocal failed
        if (
            not failed
            and destination == path
            and state.get("bicepDeployment", {}).get("submissionOutcome") == "ReturnedSuccess"
        ):
            failed = True
            raise OSError("lost CLI-result journal")
        real_persist(destination, state)

    monkeypatch.setattr(federation, "persist", save)
    state = deploy(setup)
    assert failed and state["phase"] == "ConfiguredOidcUnverified"
    assert state["bicepDeployment"]["submissionOutcome"] == "Unknown"
    assert len(runner.calls) == 2


def test_final_independent_check_failure_preserves_pending_reconciliation(setup, monkeypatch):
    config, path, api, runner = setup
    real_check = federation.check

    def fail(*args):
        raise TimeoutError("final independent GET failed")

    monkeypatch.setattr(federation, "check", fail)
    with pytest.raises(TimeoutError):
        deploy(setup)
    state = json.loads(path.read_text())
    assert state["phase"] == "BicepDeploymentRequested"
    assert state["bicepDeployment"]["phase"] == "Requested"
    with pytest.raises(ValueError, match="before teardown"):
        federation.remove(config, path, api)
    monkeypatch.setattr(federation, "check", real_check)
    assert deploy(setup)["phase"] == "ConfiguredOidcUnverified"
    assert len(runner.calls) == 2


def failed_state(setup, *, status="Failed", kinds=("identity", "federation", "role", "assignment")):
    """Crash before reconciliation so all real asset intents remain Requested."""
    _, path, _, runner = setup
    runner.status = status
    runner.outcome = "crash"
    runner.create_assets = False

    def partial():
        runner.create_assets = True
        runner.install(kinds=kinds)

    runner.after_deploy = partial
    with pytest.raises(SystemExit):
        deploy(setup)
    return json.loads(path.read_text())


def cleanup(setup):
    config, path, api, _ = setup
    federation.remove(config, path, api, allow_failed_bicep=True)


@pytest.mark.parametrize("status", ["Failed", "Canceled"])
@pytest.mark.parametrize(
    "kinds",
    [
        (),
        ("identity",),
        ("role",),
        ("identity", "federation", "role"),
        ("identity", "federation", "role", "assignment"),
    ],
)
def test_authorized_terminal_cleanup_preserves_failure_and_never_fakes_verified(
    setup, status, kinds
):
    config, path, api, runner = setup
    before = failed_state(setup, status=status, kinds=kinds)
    before_receipt = copy.deepcopy(
        api.assets[federation.deployment_path(before["bicepDeployment"])]
    )
    with pytest.raises(ValueError, match="incomplete"):
        federation.remove(config, path, api)
    cleanup(setup)
    state = json.loads(path.read_text())
    assert state["phase"] == "Removed"
    assert state["bicepDeployment"] == before["bicepDeployment"]
    assert all(asset["phase"] == "Requested" for asset in state["assets"])
    journal = state["failedBicepCleanup"]
    assert journal["phase"] == "Removed" and journal["before"] == before
    assert journal["deploymentReadback"] == before_receipt
    assert journal["proof"] == "TerminalDeployment"
    assert journal["authorization"] == "allow-failed-bicep"
    assert len(journal["assetReadbacks"]) == 4
    assert [
        asset["kind"]
        for asset in state["assets"]
        if journal["assetReadbacks"][state["assets"].index(asset)] is not None
    ] == list(kinds)
    assert [resource for method, resource in api.calls if method == "DELETE"] == [
        federation.resource_path(asset)
        for asset in reversed(before["assets"])
        if asset["kind"] in kinds
    ]
    assert "principalId" not in state or state["principalId"] == PRINCIPAL
    assert api.assets == {federation.deployment_path(before["bicepDeployment"]): before_receipt}
    evidence = copy.deepcopy(journal)
    delete_count = sum(method == "DELETE" for method, _ in api.calls)
    cleanup(setup)
    assert json.loads(path.read_text())["failedBicepCleanup"] == evidence
    assert sum(method == "DELETE" for method, _ in api.calls) == delete_count
    assert len(runner.calls) == 2
    federation.manifest_value(config, json.loads(path.read_text()))
    with pytest.raises(ValueError, match="incomplete"):
        federation.remove(config, path, api)  # The failure never becomes a Verified deployment.
    with pytest.raises(ValueError):
        deploy(setup)  # Cleanup never authorizes recreation.


@pytest.mark.parametrize("build_outcome", ["failure", "timeout", "invalid-json", "missing-hash"])
def test_authorized_local_compile_failure_cleanup_proves_no_dispatch_and_all_absent(
    setup, build_outcome
):
    config, path, api, runner = setup
    runner.build_outcome = build_outcome
    if build_outcome == "missing-hash":
        runner.template["metadata"]["_generator"].pop("templateHash")
    with pytest.raises((RuntimeError, subprocess.TimeoutExpired, ValueError)):
        deploy(setup)
    before = json.loads(path.read_text())
    with pytest.raises(ValueError, match="incomplete"):
        federation.remove(config, path, api)
    cleanup(setup)
    state = json.loads(path.read_text())
    assert state["phase"] == "Removed"
    assert state["bicepDeployment"] == before["bicepDeployment"]
    assert state["bicepDeployment"]["submissionOutcome"] == "NotSubmitted"
    assert state["failedBicepCleanup"]["before"] == before
    assert state["failedBicepCleanup"]["proof"] == "LocalNoDispatch"
    assert state["failedBicepCleanup"]["deploymentReadback"] is None
    assert state["failedBicepCleanup"]["assetReadbacks"] == [None] * 4
    assert all(asset["phase"] == "Requested" for asset in state["assets"])
    assert "principalId" not in state
    cleanup(setup)
    assert all(method == "GET" for method, _ in api.calls) and len(runner.calls) == 1


@pytest.mark.parametrize(
    "status", ["Accepted", "Running", "Creating", "Updating", "Succeeded", "foreign"]
)
def test_authorized_cleanup_cannot_override_nonterminal_or_success_receipt(setup, status):
    _, path, api, _ = setup
    failed_state(setup, status=status)
    saved = path.read_bytes()
    with pytest.raises((RuntimeError, ValueError)):
        cleanup(setup)
    assert path.read_bytes() == saved
    assert all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("outcome", ["timeout", "failure", "success"])
def test_unknown_submission_and_missing_receipt_do_not_prove_absence(setup, outcome):
    _, path, api, runner = setup
    runner.create_assets = runner.create_receipt = False
    runner.outcome = outcome
    with pytest.raises(RuntimeError):
        deploy(setup)
    saved = path.read_bytes()
    with pytest.raises(RuntimeError, match="unknown"):
        cleanup(setup)
    assert path.read_bytes() == saved
    assert all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("collision", ["receipt", "identity", "role"])
def test_local_no_dispatch_cleanup_rejects_even_exact_matching_late_collisions(setup, collision):
    _, path, api, runner = setup
    runner.build_outcome = "failure"
    with pytest.raises(RuntimeError):
        deploy(setup)
    saved = path.read_bytes()
    runner.create_receipt = collision == "receipt"
    runner.create_assets = collision != "receipt"
    runner.install(kinds=(collision,))
    with pytest.raises(ValueError, match="no-dispatch"):
        cleanup(setup)
    assert path.read_bytes() == saved
    assert all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize(
    "field",
    [
        "id",
        "name",
        "location",
        "parameters",
        "sourceSha256",
        "templateHash",
        "compiledTemplateSha256",
    ],
)
def test_cleanup_requires_saved_exact_deployment_binding_and_template(setup, field):
    _, path, api, _ = setup
    state = failed_state(setup)
    if field == "parameters":
        state["bicepDeployment"][field]["agentId"]["value"] += "-foreign"
    else:
        state["bicepDeployment"][field] = "foreign"
    federation.persist(path, state)
    saved = path.read_bytes()
    with pytest.raises((ValueError, RuntimeError)):
        cleanup(setup)
    assert path.read_bytes() == saved
    assert all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("kind", ["identity", "federation", "role", "assignment"])
def test_failed_cleanup_validates_every_present_asset_before_any_delete(setup, kind):
    _, path, api, _ = setup
    state = failed_state(setup)
    asset = next(asset for asset in state["assets"] if asset["kind"] == kind)
    live = api.assets[federation.resource_path(asset)]
    if kind == "identity":
        live["tags"]["ownerToken"] = "foreign"
    elif kind == "federation":
        live["properties"]["subject"] = "foreign"
    elif kind == "role":
        live["properties"]["assignableScopes"] = ["/subscriptions/foreign"]
    else:
        live["properties"]["principalId"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    saved = path.read_bytes()
    with pytest.raises(ValueError, match="drift"):
        cleanup(setup)
    assert path.read_bytes() == saved
    assert all(method == "GET" for method, _ in api.calls)


def test_unbound_assignment_without_identity_cannot_be_cleaned_by_guessing_principal(setup):
    _, path, api, _ = setup
    failed_state(setup, kinds=("role", "assignment"))
    saved = path.read_bytes()
    with pytest.raises(ValueError, match="principal cannot be proved"):
        cleanup(setup)
    assert path.read_bytes() == saved and all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("asset_status", ["Failed", "Canceled", "Creating", "Deleting"])
def test_cleanup_accepts_exact_terminal_failed_assets_not_active_assets(setup, asset_status):
    _, path, api, _ = setup
    before = failed_state(setup, kinds=("identity", "role"))
    live = api.assets[federation.resource_path(before["assets"][0])]
    live["properties"]["provisioningState"] = asset_status
    if asset_status in ("Failed", "Canceled"):
        cleanup(setup)
        assert json.loads(path.read_text())["phase"] == "Removed"
    else:
        saved = path.read_bytes()
        with pytest.raises(ValueError, match="provisioning"):
            cleanup(setup)
        assert path.read_bytes() == saved and all(method == "GET" for method, _ in api.calls)


@pytest.mark.parametrize("lost_kind", ["role", "identity"])
def test_failed_cleanup_retry_after_lost_delete_keeps_requested_intents_and_original_evidence(
    setup, monkeypatch, lost_kind
):
    _, path, api, runner = setup
    before = failed_state(setup)
    real_request = api.request
    lost = False

    def request(method, resource, body=None):
        nonlocal lost
        result = real_request(method, resource, body)
        asset = next(
            (asset for asset in before["assets"] if federation.resource_path(asset) == resource),
            None,
        )
        if not lost and method == "DELETE" and asset["kind"] == lost_kind:
            lost = True
            journal = json.loads(path.read_text())["failedBicepCleanup"]
            assert journal["before"] == before and journal["phase"] == "Requested"
            raise TimeoutError("lost DELETE response")
        return result

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(TimeoutError):
        cleanup(setup)
    during = json.loads(path.read_text())
    assert during["phase"] == "Removing"
    assert all(asset["phase"] == "Requested" for asset in during["assets"])
    original_evidence = copy.deepcopy(during["failedBicepCleanup"])
    cleanup(setup)
    state = json.loads(path.read_text())
    assert state["phase"] == "Removed"
    assert state["failedBicepCleanup"] == {**original_evidence, "phase": "Removed"}
    cleanup(setup)
    assert [resource for method, resource in api.calls if method == "DELETE"] == [
        federation.resource_path(asset) for asset in reversed(before["assets"])
    ]
    assert len(runner.calls) == 2


@pytest.mark.parametrize("field", ["clientId", "principalId", "tenantId"])
def test_failed_cleanup_retains_identity_binding_even_after_identity_is_deleted(
    setup, monkeypatch, field
):
    _, path, api, _ = setup
    before = failed_state(setup)
    real_request = api.request
    identity_path = federation.resource_path(before["assets"][0])

    def request(method, resource, body=None):
        result = real_request(method, resource, body)
        if method == "DELETE" and resource == identity_path:
            raise TimeoutError("identity deleted; response lost")
        return result

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(TimeoutError):
        cleanup(setup)
    state = json.loads(path.read_text())
    state[field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    if field == "principalId":
        state["assets"][-1]["body"]["properties"]["principalId"] = state[field]
    federation.persist(path, state)
    count = len(api.calls)
    with pytest.raises(ValueError, match="identity binding changed"):
        cleanup(setup)
    assert all(method == "GET" for method, _ in api.calls[count:])


@pytest.mark.parametrize("lost_kind", ["role", "identity"])
def test_normal_down_repeats_when_identity_or_role_already_removed(setup, monkeypatch, lost_kind):
    config, path, api, _ = setup
    before = deploy(setup)
    real_request = api.request
    lost = False

    def request(method, resource, body=None):
        nonlocal lost
        result = real_request(method, resource, body)
        asset = next(
            (asset for asset in before["assets"] if federation.resource_path(asset) == resource),
            None,
        )
        if not lost and method == "DELETE" and asset["kind"] == lost_kind:
            lost = True
            raise TimeoutError("lost normal teardown response")
        return result

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(TimeoutError):
        federation.remove(config, path, api)
    assert json.loads(path.read_text())["phase"] == "Removing"
    federation.remove(config, path, api)
    federation.remove(config, path, api)
    assert json.loads(path.read_text())["phase"] == "Removed"
    assert [resource for method, resource in api.calls if method == "DELETE"] == [
        federation.resource_path(asset) for asset in reversed(before["assets"])
    ]


def test_failed_cleanup_storage_failure_prevents_deletion(setup, monkeypatch):
    _, path, api, _ = setup
    failed_state(setup)
    saved = path.read_bytes()

    def fail(*args):
        raise OSError("failure evidence not durable")

    monkeypatch.setattr(federation, "persist", fail)
    with pytest.raises(OSError):
        cleanup(setup)
    assert path.read_bytes() == saved and all(method == "GET" for method, _ in api.calls)


def test_failed_cleanup_get_failure_cannot_claim_requested_absence(setup):
    _, path, api, _ = setup
    failed_state(setup, kinds=())
    saved = path.read_bytes()
    api.error = TimeoutError("GET absence unproven")
    with pytest.raises(TimeoutError):
        cleanup(setup)
    assert path.read_bytes() == saved and all(method == "GET" for method, _ in api.calls)


def test_failed_cleanup_cli_flag_uses_existing_lock_and_keeps_default_closed(
    setup, tmp_path, monkeypatch
):
    config, path, api, runner = setup
    failed_state(setup, kinds=("identity", "role"))
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(config))
    args = ["federation", "down", "--config", str(config_path), "--state", str(path)]
    monkeypatch.setattr(sys, "argv", args)
    monkeypatch.setattr(federation, "arm_token", lambda _: "fake-arm-token")
    monkeypatch.setattr(federation, "Api", lambda origin, token: api)
    with pytest.raises(ValueError, match="incomplete"):
        federation.main()
    assert not path.with_suffix(".lock").exists()
    real_request = api.request

    def request(method, resource, body=None):
        assert path.with_suffix(".lock").exists()
        return real_request(method, resource, body)

    monkeypatch.setattr(api, "request", request)
    monkeypatch.setattr(sys, "argv", [*args, "--allow-failed-bicep"])
    federation.main()
    assert json.loads(path.read_text())["phase"] == "Removed"
    assert not path.with_suffix(".lock").exists()
    federation.main()
    assert len(runner.calls) == 2


def test_failed_cleanup_flag_rejected_on_other_operations_before_auth(setup, tmp_path, monkeypatch):
    config, _, _, runner = setup
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(config))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "federation",
            "bicep-spec",
            "--config",
            str(config_path),
            "--location",
            LOCATION,
            "--expires-at",
            EXPIRY,
            "--allow-failed-bicep",
        ],
    )
    monkeypatch.setattr(
        federation, "arm_token", lambda _: pytest.fail("invalid flag acquired token")
    )
    with pytest.raises(ValueError, match="only with down"):
        federation.main()
    assert not runner.calls


def test_corrected_source_cannot_replay_or_replace_old_returned_failure_journal(setup, monkeypatch):
    _, path, api, runner = setup
    runner.create_assets = runner.create_receipt = False
    runner.outcome = "failure"
    with pytest.raises(RuntimeError, match="never replay"):
        deploy(setup)
    state = json.loads(path.read_text())
    # Represent a journal frozen by the prior module, not the now-corrected file.
    state["bicepDeployment"]["sourceSha256"] = "a" * 64
    state["bicepDeployment"]["compiledTemplateSha256"] = "b" * 64
    federation.persist(path, state)
    saved = path.read_bytes()
    monkeypatch.setattr(
        federation, "azure_cli_executable", lambda: pytest.fail("retry invoked CLI")
    )
    with pytest.raises(RuntimeError, match="never replay"):
        deploy(setup)
    with pytest.raises(RuntimeError, match="unknown"):
        cleanup(setup)
    assert path.read_bytes() == saved
    # A receipt for a different (corrected) compiled template cannot be adopted.
    runner.create_receipt = True
    runner.status = "Failed"
    runner.template["metadata"]["_generator"]["templateHash"] = "987654321"
    runner.install()
    with pytest.raises(ValueError, match="frozen parameters/template"):
        deploy(setup)
    with pytest.raises(ValueError, match="frozen parameters/template"):
        cleanup(setup)
    assert path.read_bytes() == saved and len(runner.calls) == 2
    assert all(method == "GET" for method, _ in api.calls)
