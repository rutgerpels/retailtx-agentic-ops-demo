"""Operator-owned ARM caller identity, federation and exact-agent invocation grant."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

from scripts.github.intake import (
    ROOT,
    Api,
    azure_cli_executable,
    digest,
    object_value,
    positive_id,
    utc,
    validate_config,
)
from scripts.github.lifecycle import get_optional, persist

IDENTITY_VERSION = "2023-01-31"
AUTH_VERSION = "2022-04-01"
ROLE_PROFILE = "investigator-read-v1"
CONFIGURATION_READ = "Microsoft.App/agents/extendedagents/read"
BICEP_MODULE = ROOT / "infra" / "github-intake-identity.bicep"
DEPLOYMENT_VERSION = "2022-09-01"
BICEP_READBACK_SECONDS = 120


def federation_subject(config: dict[str, Any]) -> str:
    classic = f"repo:{config['repository']}:environment:sre-github-intake"
    if "oidc" not in config:
        # Preserve classic manifests for exact inverse checks, not new setup.
        return classic
    oidc = object_value(config["oidc"])
    if set(oidc) != {"repositoryOwnerId", "subject"}:
        raise ValueError("Explicit OIDC owner ID and verified subject are required")
    owner_id = positive_id(oidc["repositoryOwnerId"])
    owner, repository = config["repository"].split("/")
    immutable = (
        f"repo:{owner}@{owner_id}/{repository}@{config['repositoryId']}"
        ":environment:sre-github-intake"
    )
    subject = oidc["subject"]
    if not isinstance(subject, str) or subject not in (classic, immutable):
        raise ValueError("OIDC subject differs from exact repository/owner/environment binding")
    return subject


def repository_binding(config: dict[str, Any], evidence: Any) -> dict[str, Any]:
    federation_subject(config)
    if "oidc" not in config:
        raise ValueError("Explicit verified OIDC configuration is required")
    repository = object_value(evidence)
    owner = object_value(repository.get("owner"))
    if (
        repository.get("full_name") != config["repository"]
        or positive_id(repository.get("id")) != config["repositoryId"]
        or owner.get("login") != config["repository"].split("/")[0]
        or positive_id(owner.get("id")) != config["oidc"]["repositoryOwnerId"]
    ):
        raise ValueError("Repository API owner/name/ID differs from trusted OIDC binding")
    return {
        "full_name": repository["full_name"], "id": repository["id"],
        "owner": {"login": owner["login"], "id": owner["id"]},
    }


def binding_hash(config: dict[str, Any]) -> str:
    binding = {key: config[key] for key in (
        "repository", "repositoryId", "environment", "binding",
    )}
    if "oidc" in config:
        binding["oidc"] = config["oidc"]
    return digest(binding)


def role_profile(state: dict[str, Any]) -> str | None:
    if "roleProfile" not in state:
        return None
    if state["roleProfile"] != ROLE_PROFILE:
        raise ValueError("Unknown federation role profile; no adoption/migration")
    return ROLE_PROFILE


def specifications(config: dict[str, Any], location: str, expires_at: str, *,
                   profile: str | None = ROLE_PROFILE) -> list[dict[str, Any]]:
    validate_config(config, ready=False)
    if profile not in (None, ROLE_PROFILE):
        raise ValueError("Unknown federation role profile")
    if not re.fullmatch(r"[a-z][a-z0-9]{1,40}", location):
        raise ValueError("Invalid trusted identity location")
    utc(expires_at)
    binding = config["binding"]
    group = binding["agentId"].split("/providers/", 1)[0]
    identity = group + "/providers/Microsoft.ManagedIdentity/userAssignedIdentities/" + (
        f"retailtx-github-intake-{config['environment']}"
    )
    namespace = uuid.UUID(binding["ownerToken"])
    role = f"/subscriptions/{binding['subscriptionId']}/providers/Microsoft.Authorization/" + (
        "roleDefinitions/" + str(uuid.uuid5(namespace, "github-intake-role:" + binding["agentId"]))
    )
    assignment = binding["agentId"] + "/providers/Microsoft.Authorization/roleAssignments/" + (
        str(uuid.uuid5(namespace, "github-intake-assignment:" + identity))
    )
    return [
        {
            "kind": "identity", "id": identity, "apiVersion": IDENTITY_VERSION,
            "body": {"location": location, "tags": {
                "demo": "retailtx", "environmentId": config["environment"],
                "profile": "github-intake", "managedBy": "retailtx",
                "ownerToken": binding["ownerToken"], "expiresAt": expires_at,
            }},
        },
        {
            "kind": "federation", "id": identity + "/federatedIdentityCredentials/github-intake",
            "apiVersion": IDENTITY_VERSION,
            "body": {"properties": {
                "issuer": "https://token.actions.githubusercontent.com",
                "subject": federation_subject(config),
                "audiences": ["api://AzureADTokenExchange"],
            }},
        },
        {
            "kind": "role", "id": role, "apiVersion": AUTH_VERSION,
            "body": {"properties": {
                "roleName": f"RetailTx GitHub intake {config['environment']} {namespace}",
                "description": f"Proposal-only GitHub intake; ownerToken={namespace}",
                "type": "CustomRole", "assignableScopes": [group],
                "permissions": [{
                    "actions": ["Microsoft.App/agents/read"], "notActions": [],
                    "dataActions": [
                        "Microsoft.App/agents/threads/read", "Microsoft.App/agents/threads/write",
                    ] + ([CONFIGURATION_READ] if profile == ROLE_PROFILE else []),
                    "notDataActions": [],
                }],
            }},
        },
        {
            "kind": "assignment", "id": assignment, "apiVersion": AUTH_VERSION,
            "body": {"properties": {
                "roleDefinitionId": role, "principalType": "ServicePrincipal",
                "principalId": "<owned-identity-principal>",
            }},
        },
    ]


def resource_path(asset: dict[str, Any]) -> str:
    return f"{asset['id']}?api-version={asset['apiVersion']}"


def validate_asset(asset: dict[str, Any], live: dict[str, Any], *,
                   allow_terminal_failure: bool = False) -> None:
    if str(live.get("id", "")).lower() != asset["id"].lower():
        raise ValueError("ARM asset identity differs from owned intent")
    for key, expected in asset["body"].items():
        actual = live.get(key)
        if isinstance(expected, dict):
            actual = object_value(actual)
            for field, value in expected.items():
                if actual.get(field) != value:
                    raise ValueError("Owned identity/federation/role drift; no overwrite/delete")
        elif actual != expected:
            raise ValueError("Owned ARM configuration differs")
    properties = object_value(live.get("properties", {}))
    if asset["kind"] == "identity":
        for key in ("clientId", "principalId", "tenantId"):
            value = properties[key]
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError("Managed identity response lacks canonical identity IDs")
    allowed_states = (
        ("Succeeded", "Failed", "Canceled") if allow_terminal_failure else ("Succeeded",)
    )
    if properties.get("provisioningState", "Succeeded") not in allowed_states:
        raise ValueError("Owned resource provisioning not verified")


def bind_identity(state: dict[str, Any], live: dict[str, Any], *, capture: bool = False) -> None:
    keys = ("clientId", "principalId", "tenantId")
    properties = object_value(live["properties"])
    recorded = [key in state for key in keys]
    if not any(recorded) and capture:
        state.update({key: properties[key] for key in keys})
    elif not all(recorded) or any(properties[key] != state[key] for key in keys):
        raise ValueError("Managed identity principal/client/tenant changed; no adoption/delete")


def manifest(config: dict[str, Any], path: Path) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    return manifest_value(config, state)


def manifest_value(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    if state.get("phase") == "SubjectTransitionRequested":
        raise ValueError(
            "Subject transition uncertain; reconcile transition GET before reuse/delete",
        )
    if state.get("phase") == "RoleTransitionRequested":
        raise ValueError("Role transition uncertain; reconcile upgrade GET before reuse/delete")
    if "roleTransition" in state:
        role_transition_plan(config, state)
    if (state.get("ownerToken") != config["binding"]["ownerToken"]
            or state.get("configHash") != binding_hash(config)):
        raise ValueError("Foreign/changed federation manifest")
    assets = state["assets"]
    if not isinstance(assets, list) or len(assets) != 4:
        raise ValueError("Incomplete federation manifest")
    desired = specifications(
        config, assets[0]["body"]["location"], assets[0]["body"]["tags"]["expiresAt"],
        profile=role_profile(state),
    )
    principal = assets[-1]["body"]["properties"]["principalId"]
    allowed_principals = (state.get("principalId"), "<owned-identity-principal>")
    # Unlike sequential ARM setup, Bicep journals the assignment before the
    # identity exists. Only that exact pending, wholly unbound state may retain
    # the placeholder; a verified/rebound assignment still requires the real ID.
    unbound_bicep = (
        (state.get("phase") == "BicepDeploymentRequested" or (
            state.get("phase") in ("Removing", "Removed")
            and isinstance(state.get("failedBicepCleanup"), dict)
            and state["failedBicepCleanup"].get("authorization") == "allow-failed-bicep"
        ))
        and isinstance(state.get("bicepDeployment"), dict)
        and state["bicepDeployment"].get("phase") == "Requested"
        and assets[0].get("phase") == "Requested"
        and assets[-1].get("phase") == "Requested"
        and not any(key in state for key in ("clientId", "principalId", "tenantId"))
        and principal == "<owned-identity-principal>"
    )
    if principal not in allowed_principals or (
        assets[-1].get("phase") and principal != state.get("principalId") and not unbound_bicep
    ):
        raise ValueError("Federation assignment principal changed")
    desired[-1]["body"]["properties"]["principalId"] = principal
    normalized = [{key: value for key, value in asset.items() if key != "phase"}
                  for asset in assets]
    if normalized != desired:
        raise ValueError("Federation manifest paths/specification changed")
    return state


def configure(config: dict[str, Any], path: Path, api: Api,
              location: str, expires_at: str, repository_evidence: Any = None) -> dict[str, Any]:
    if "oidc" in config or not path.exists():
        repository_binding(config, repository_evidence)
    if path.exists():
        state = manifest(config, path)
        if "bicepDeployment" in state:
            raise ValueError(
                "Bicep-owned federation requires deploy-bicep reconciliation; no ARM PUT",
            )
        desired = specifications(config, location, expires_at, profile=role_profile(state))
        normalized = json.loads(json.dumps(state["assets"]))
        normalized[-1]["body"]["properties"]["principalId"] = "<owned-identity-principal>"
        for asset in normalized:
            asset.pop("phase", None)
        if normalized != desired or state.get("phase") == "Removed":
            raise ValueError("Federation intent changed; no adoption/recreation")
    else:
        desired = specifications(config, location, expires_at)
        for asset in desired:
            if get_optional(api, resource_path(asset)) is not None:
                raise ValueError("Unowned federation collision; no adoption")
        state = {
            "schemaVersion": 1, "ownerToken": config["binding"]["ownerToken"],
            "configHash": binding_hash(config), "roleProfile": ROLE_PROFILE,
            "assets": desired, "phase": "Configuring",
        }
        persist(path, state)
    for asset in state["assets"]:
        if asset["kind"] == "assignment":
            asset["body"]["properties"]["principalId"] = state["principalId"]
        live = get_optional(api, resource_path(asset))
        if live is not None:
            if asset.get("phase") not in ("Requested", "Verified"):
                raise ValueError("Late unowned federation collision")
        elif asset.get("phase"):
            raise RuntimeError("ARM request absent/uncertain; never replay PUT")
        else:
            asset["phase"] = "Requested"
            persist(path, state)
            status, _ = api.request("PUT", resource_path(asset), asset["body"])
            if status not in (200, 201, 202):
                raise RuntimeError("ARM write uncertain; reconcile GET without replay")
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                live = get_optional(api, resource_path(asset))
                if live is not None and live.get("properties", {}).get(
                    "provisioningState", "Succeeded"
                ) == "Succeeded":
                    break
                time.sleep(min(2, max(0, deadline - time.monotonic())))
            if live is None:
                raise RuntimeError("Owned ARM resource creation not observed")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live, capture=asset["phase"] == "Requested")
        asset["phase"] = "Verified"
        persist(path, state)
    state["phase"] = "ConfiguredOidcUnverified"
    persist(path, state)
    return state


def bicep_spec(config: dict[str, Any], location: str, expires_at: str) -> dict[str, Any]:
    """Pure deployment plan; specifications remain the ownership source of truth."""
    assets = specifications(config, location, expires_at)
    if "oidc" not in config:
        raise ValueError("Explicit verified OIDC configuration is required")
    binding = config["binding"]
    parameters = {
        "environment": config["environment"],
        "location": location,
        "ownerToken": binding["ownerToken"],
        "agentId": binding["agentId"],
        "repository": config["repository"],
        "repositoryId": config["repositoryId"],
        "repositoryOwnerId": config["oidc"]["repositoryOwnerId"],
        "verifiedOidcSubject": federation_subject(config),
        "expiresAt": expires_at,
        "roleDefinitionName": assets[2]["id"].rsplit("/", 1)[1],
        "roleAssignmentName": assets[3]["id"].rsplit("/", 1)[1],
    }
    suffix = uuid.uuid5(
        uuid.UUID(binding["ownerToken"]), "github-intake-bicep:" + binding["agentId"]
    )
    name = f"gh-intake-{config['environment']}-{suffix.hex}"
    return {
        "assets": assets,
        "deployment": {
            "id": f"/subscriptions/{binding['subscriptionId']}/providers/"
            f"Microsoft.Resources/deployments/{name}",
            "name": name,
            "apiVersion": DEPLOYMENT_VERSION,
            "location": location,
            "parameters": {key: {"value": value} for key, value in parameters.items()},
        },
    }


def deployment_path(deployment: dict[str, Any]) -> str:
    return f"{deployment['id']}?api-version={deployment['apiVersion']}"


def bicep_collisions(plan: dict[str, Any], api: Api) -> None:
    # Check every owned resource, including the deployment receipt, before submission.
    paths = [resource_path(asset) for asset in plan["assets"]]
    paths.append(deployment_path(plan["deployment"]))
    readbacks = [get_optional(api, path) for path in paths]
    if any(live is not None for live in readbacks):
        raise ValueError("Unowned Bicep federation/deployment collision; no adoption")


def validate_bicep_receipt(deployment: dict[str, Any], live: dict[str, Any]) -> str:
    if str(live.get("id", "")).lower() != deployment["id"].lower():
        raise ValueError("Bicep deployment receipt ID differs from owned intent")
    properties = object_value(live.get("properties"))
    parameters = object_value(properties.get("parameters"))
    actual = {key: {"value": object_value(value).get("value")} for key, value in parameters.items()}
    if (
        live.get("location") != deployment["location"]
        or properties.get("mode") != "Incremental"
        or actual != deployment["parameters"]
        or not deployment.get("templateHash")
        or str(properties.get("templateHash")) != deployment["templateHash"]
    ):
        raise ValueError(
            "Bicep deployment receipt differs from frozen parameters/template; no adoption"
        )
    status = properties.get("provisioningState")
    if status not in (
        "Accepted",
        "Running",
        "Creating",
        "Updating",
        "Succeeded",
        "Failed",
        "Canceled",
    ):
        raise ValueError("Bicep deployment receipt lacks a recognized provisioning state")
    return status


def reconcile_bicep(
    config: dict[str, Any], path: Path, api: Api, state: dict[str, Any]
) -> dict[str, Any]:
    """GET-only after a durable submission intent, including lost/failed CLI outcomes."""
    deployment = state["bicepDeployment"]
    deadline = time.monotonic() + BICEP_READBACK_SECONDS
    while True:
        receipt = get_optional(api, deployment_path(deployment))
        snapshots = [get_optional(api, resource_path(asset)) for asset in state["assets"]]
        if deployment["submissionOutcome"] == "NotSubmitted":
            raise RuntimeError(
                "Bicep submission was not journaled; GET-only, never replay deployment"
            )
        status = validate_bicep_receipt(deployment, receipt) if receipt is not None else None
        if receipt is not None:
            # Pin identity IDs as soon as independent readback proves creation. This
            # remains durable even if the assignment or deployment is still pending.
            for asset, live in zip(state["assets"], snapshots, strict=True):
                if live is None:
                    if asset["phase"] == "Verified":
                        raise ValueError("Verified Bicep federation asset missing; no recreation")
                    continue
                if (
                    object_value(live.get("properties", {})).get("provisioningState", "Succeeded")
                    != "Succeeded"
                ):
                    if asset["phase"] == "Verified":
                        raise ValueError(
                            "Verified Bicep federation asset changed provisioning state"
                        )
                    continue
                if asset["kind"] == "assignment":
                    if "principalId" not in state:
                        continue
                    asset["body"]["properties"]["principalId"] = state["principalId"]
                validate_asset(asset, live)
                if asset["kind"] == "identity":
                    bind_identity(state, live, capture=asset["phase"] == "Requested")
                    state["assets"][-1]["body"]["properties"]["principalId"] = state["principalId"]
                asset["phase"] = "Verified"
                persist(path, state)
            if status == "Succeeded" and all(
                asset["phase"] == "Verified" for asset in state["assets"]
            ):
                deployment["phase"] = "Verified"
                state["phase"] = "ConfiguredOidcUnverified"
                manifest_value(config, state)
                persist(path, state)
                try:
                    check(config, path, api)
                except Exception:
                    state["phase"] = "BicepDeploymentRequested"
                    deployment["phase"] = "Requested"
                    persist(path, state)
                    raise
                return state
            if status in ("Failed", "Canceled"):
                raise RuntimeError(
                    f"Bicep deployment {status}; retain intent, GET-only, never replay"
                )
        if time.monotonic() >= deadline:
            raise RuntimeError(
                "Bicep deployment/asset creation uncertain; GET-only, never replay deployment"
            )
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def deploy_bicep(
    config: dict[str, Any],
    path: Path,
    api: Api,
    location: str,
    expires_at: str,
    repository_evidence: Any = None,
) -> dict[str, Any]:
    """Submit Bicep once; Python writes only deployment control-plane, never asset PUTs."""
    repository_binding(config, repository_evidence)
    plan = bicep_spec(config, location, expires_at)
    if path.exists():
        state = manifest(config, path)
        if "bicepDeployment" not in state:
            raise ValueError("No owned Bicep submission intent; no adoption")
        deployment = object_value(state["bicepDeployment"])
        if (
            role_profile(state) != ROLE_PROFILE
            or state.get("phase") not in ("BicepDeploymentRequested", "ConfiguredOidcUnverified")
            or deployment.get("phase") not in ("Requested", "Verified")
            or deployment.get("submissionOutcome")
            not in ("NotSubmitted", "Unknown", "ReturnedSuccess", "ReturnedFailure")
            or any(asset.get("phase") not in ("Requested", "Verified") for asset in state["assets"])
        ):
            raise ValueError("Changed/incomplete Bicep manifest; no adoption/recreation")
        if any(deployment.get(key) != value for key, value in plan["deployment"].items()):
            raise ValueError("Bicep deployment intent changed; no adoption/recreation")
        normalized = copy.deepcopy(state["assets"])
        for asset in normalized:
            asset.pop("phase", None)
        normalized[-1]["body"]["properties"]["principalId"] = "<owned-identity-principal>"
        if normalized != plan["assets"]:
            raise ValueError("Bicep federation intent changed; no adoption/recreation")
        # No CLI execution, compilation, token acquisition or resubmission here.
        return reconcile_bicep(config, path, api, state)

    executable = azure_cli_executable()
    source_hash = hashlib.sha256(BICEP_MODULE.read_bytes()).hexdigest()
    bicep_collisions(plan, api)
    state = {
        "schemaVersion": 1,
        "ownerToken": config["binding"]["ownerToken"],
        "configHash": binding_hash(config),
        "roleProfile": ROLE_PROFILE,
        "assets": [{**asset, "phase": "Requested"} for asset in plan["assets"]],
        "phase": "BicepDeploymentRequested",
        "bicepDeployment": {
            **plan["deployment"],
            "phase": "Requested",
            "sourceSha256": source_hash,
            "submissionOutcome": "NotSubmitted",
        },
    }
    # All four exact intents are fsynced before even the local Bicep invocation.
    persist(path, state)
    compiled = subprocess.run(
        [executable, "bicep", "build", "--file", str(BICEP_MODULE), "--no-restore", "--stdout"],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
        shell=False,
    )
    if compiled.returncode:
        raise RuntimeError("Bicep compilation failed; deployment not submitted; retain intent")
    template = object_value(json.loads(compiled.stdout))
    if hashlib.sha256(BICEP_MODULE.read_bytes()).hexdigest() != source_hash:
        raise ValueError("Bicep source changed during compilation; deployment not submitted")
    template_hash = str(
        object_value(object_value(template.get("metadata")).get("_generator")).get(
            "templateHash", ""
        )
    )
    if not re.fullmatch(r"[0-9]+", template_hash):
        raise ValueError("Compiled Bicep template lacks a frozen template hash")
    state["bicepDeployment"]["templateHash"] = template_hash
    state["bicepDeployment"]["compiledTemplateSha256"] = digest(template)
    persist(path, state)
    # Compilation can take time. A late collision still must not be adopted.
    bicep_collisions(plan, api)
    with tempfile.TemporaryDirectory(prefix="github-intake-bicep-", dir=path.parent) as temporary:
        template_path = Path(temporary) / "template.json"
        parameters_path = Path(temporary) / "parameters.json"
        persist(template_path, template)
        persist(
            parameters_path,
            {
                "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
                "contentVersion": "1.0.0.0",
                "parameters": plan["deployment"]["parameters"],
            },
        )
        # The WAL marker precedes the one possible control-plane submission.
        state["bicepDeployment"]["submissionOutcome"] = "Unknown"
        persist(path, state)
        try:
            completed = subprocess.run(
                [
                    executable,
                    "deployment",
                    "sub",
                    "create",
                    "--subscription",
                    config["binding"]["subscriptionId"],
                    "--name",
                    plan["deployment"]["name"],
                    "--location",
                    location,
                    "--template-file",
                    str(template_path),
                    "--parameters",
                    "@" + str(parameters_path),
                    "--output",
                    "none",
                    "--only-show-errors",
                ],
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
                shell=False,
            )
        except (OSError, subprocess.SubprocessError):
            # Lost responses are reconciled by GET in this invocation and every retry.
            pass
        else:
            state["bicepDeployment"]["submissionOutcome"] = (
                "ReturnedFailure" if completed.returncode else "ReturnedSuccess"
            )
            try:
                persist(path, state)
            except OSError:
                # The durable pre-call WAL is still Unknown. Reconcile even if
                # journaling the CLI return failed; never infer success from it.
                state["bicepDeployment"]["submissionOutcome"] = "Unknown"
    return reconcile_bicep(config, path, api, state)


def subject_transition_spec(config: dict[str, Any], state: dict[str, Any],
                            repository_evidence: Any) -> dict[str, Any]:
    """Pure, owner-reviewed classic-to-immutable plan; never authenticates or writes."""
    validate_config(config, ready=False)
    if "roleTransition" in state:
        raise ValueError("Role upgrade history cannot be rewritten by a subject transition")
    repository = repository_binding(config, repository_evidence)
    classic = f"repo:{config['repository']}:environment:sre-github-intake"
    if federation_subject(config) == classic:
        raise ValueError("Subject transition requires an explicit immutable target")
    previous = copy.deepcopy(config)
    previous.pop("oidc")
    if binding_hash(previous) != state.get("configHash"):
        previous["oidc"] = {**config["oidc"], "subject": classic}
    manifest_value(previous, state)
    if (
        state.get("phase") != "ConfiguredOidcUnverified"
        or any(asset.get("phase") != "Verified" for asset in state["assets"])
        or "subjectTransition" in state
    ):
        raise ValueError("Transition requires four verified assets and no previous transition")
    after = copy.deepcopy(state)
    after["assets"][1]["body"]["properties"]["subject"] = federation_subject(config)
    after["configHash"] = binding_hash(config)
    manifest_value(config, after)
    return {"before": copy.deepcopy(state), "after": after, "repository": repository}


def transition_readback(state: dict[str, Any], api: Api) -> list[dict[str, Any]]:
    snapshots = []
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is None:
            raise ValueError("Owned transition asset missing; no creation/adoption")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)
        snapshots.append(live)
    return snapshots


def transition_subject(config: dict[str, Any], path: Path, api: Api,
                       repository_evidence: Any) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if "roleTransition" in state or state.get("phase") == "RoleTransitionRequested":
        raise ValueError("Role upgrade history cannot be rewritten by a subject transition")
    journal = state.get("subjectTransition")
    if journal is None:
        plan = subject_transition_spec(config, state, repository_evidence)
        before_readback = transition_readback(plan["before"], api)
        journal = {
            "phase": "Requested", "before": plan["before"], "after": plan["after"],
            "repository": plan["repository"], "beforeReadback": before_readback,
        }
        state["phase"] = "SubjectTransitionRequested"
        state["subjectTransition"] = journal
        persist(path, state)
        asset = plan["after"]["assets"][1]
        status, _ = api.request("PUT", resource_path(asset), asset["body"])
        if status not in (200, 201):
            raise RuntimeError("Subject write uncertain; reconcile GET without replay")
    else:
        journal = object_value(journal)
        plan = subject_transition_spec(config, journal["before"], repository_evidence)
        if any(journal.get(key) != plan[key] for key in ("before", "after", "repository")):
            raise ValueError("Subject transition intent changed; no replay/adoption")
        for asset, live in zip(
            plan["before"]["assets"], journal["beforeReadback"], strict=True,
        ):
            validate_asset(asset, object_value(live))
            if asset["kind"] == "identity":
                bind_identity(plan["before"], live)
        expected = copy.deepcopy(plan["before"] if journal["phase"] == "Requested"
                                 else plan["after"])
        expected["phase"] = ("SubjectTransitionRequested" if journal["phase"] == "Requested"
                             else "ConfiguredOidcUnverified")
        expected["subjectTransition"] = journal
        if journal["phase"] not in ("Requested", "Verified") or state != expected:
            raise ValueError("Subject transition manifest changed; no replay/adoption")
    # Once intent is durable, every retry is GET-only, even if the old subject remains.
    readback = transition_readback(plan["after"], api)
    compare_transition_readbacks(
        journal["beforeReadback"], readback, 1, {"subject": federation_subject(config)},
    )
    state = copy.deepcopy(plan["after"])
    state["subjectTransition"] = {**journal, "phase": "Verified", "readback": readback}
    persist(path, state)
    return state


def role_upgrade_spec(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    """Pure, fixed legacy-to-configuration-read plan; no runtime config change."""
    validate_config(config, ready=False)
    if "roleTransition" in state:
        raise ValueError("Role upgrade requires original legacy state, not transition history")
    manifest_value(config, state)
    if (
        role_profile(state) is not None
        or type(state.get("schemaVersion")) is not int or state["schemaVersion"] != 1
        or state.get("phase") != "ConfiguredOidcUnverified"
        or any(asset.get("phase") != "Verified" for asset in state["assets"])
    ):
        raise ValueError("Role upgrade requires four verified legacy assets")
    for key in ("clientId", "principalId", "tenantId"):
        value = state.get(key)
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError("Role upgrade requires canonical recorded identity IDs")
    if "subjectTransition" in state:
        journal = object_value(state["subjectTransition"])
        if (
            set(journal) != {
                "phase", "before", "after", "repository", "beforeReadback", "readback",
            }
            or journal["phase"] != "Verified"
            or "subjectTransition" in object_value(journal["before"])
            or "roleTransition" in journal["before"]
        ):
            raise ValueError("Incomplete subject transition history; no role upgrade")
        subject_plan = subject_transition_spec(config, journal["before"], journal["repository"])
        if any(journal[key] != subject_plan[key] for key in ("before", "after", "repository")):
            raise ValueError("Subject transition history changed; no role upgrade")
        expected = copy.deepcopy(subject_plan["after"])
        expected["subjectTransition"] = journal
        if state != expected:
            raise ValueError("Subject transition manifest changed; no role upgrade")
        validate_snapshots(subject_plan["before"], journal["beforeReadback"])
        validate_snapshots(subject_plan["after"], journal["readback"])
        compare_transition_readbacks(
            journal["beforeReadback"], journal["readback"], 1,
            {"subject": federation_subject(config)},
        )
    after = copy.deepcopy(state)
    after["roleProfile"] = ROLE_PROFILE
    after["assets"][2]["body"]["properties"]["permissions"][0]["dataActions"].append(
        CONFIGURATION_READ,
    )
    return {"before": copy.deepcopy(state), "after": after}


def validate_snapshots(state: dict[str, Any], snapshots: Any) -> None:
    if not isinstance(snapshots, list) or len(snapshots) != 4:
        raise ValueError("Incomplete transition readbacks")
    for asset, live in zip(state["assets"], snapshots, strict=True):
        live = object_value(live)
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)


def compare_transition_readbacks(before: list[dict[str, Any]], after: list[dict[str, Any]],
                                changed_index: int, properties: dict[str, Any]) -> None:
    for index, (original, current) in enumerate(zip(before, after, strict=True)):
        expected, actual = copy.deepcopy(original), copy.deepcopy(current)
        if index == changed_index:
            expected["properties"].update(properties)
            expected.pop("systemData", None)
            actual.pop("systemData", None)
            if changed_index == 2:
                # ARM owns these role update stamps, not the permission intent.
                for key in ("updatedBy", "updatedOn"):
                    expected["properties"].pop(key, None)
                    actual["properties"].pop(key, None)
        if expected != actual:
            raise ValueError("Transition changed other ARM fields; completion unverified")


def role_transition_plan(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    journal = object_value(state["roleTransition"])
    phase = journal.get("phase")
    required = {"phase", "before", "after", "beforeReadback"}
    if phase == "Verified":
        required.add("readback")
    if phase not in ("Requested", "Verified") or set(journal) != required:
        raise ValueError("Incomplete role transition journal; no replay/adoption")
    plan = role_upgrade_spec(config, object_value(journal["before"]))
    if any(journal[key] != plan[key] for key in ("before", "after")):
        raise ValueError("Role transition intent changed; no replay/adoption")
    validate_snapshots(plan["before"], journal["beforeReadback"])
    expected = copy.deepcopy(plan["before"] if phase == "Requested" else plan["after"])
    if phase == "Requested":
        expected["phase"] = "RoleTransitionRequested"
    elif state.get("phase") in ("Removing", "Removed"):
        expected["phase"] = state["phase"]
    expected["roleTransition"] = journal
    if state != expected:
        raise ValueError("Role transition manifest changed; no replay/adoption")
    if phase == "Verified":
        validate_snapshots(plan["after"], journal["readback"])
        compare_transition_readbacks(
            journal["beforeReadback"], journal["readback"], 2,
            plan["after"]["assets"][2]["body"]["properties"],
        )
    return plan


def upgrade_role(config: dict[str, Any], path: Path, api: Api) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if "roleTransition" not in state:
        plan = role_upgrade_spec(config, state)
        before_readback = transition_readback(plan["before"], api)
        journal = {
            "phase": "Requested", **plan, "beforeReadback": before_readback,
        }
        state["phase"] = "RoleTransitionRequested"
        state["roleTransition"] = journal
        persist(path, state)
        asset = plan["after"]["assets"][2]
        status, _ = api.request("PUT", resource_path(asset), asset["body"])
        if status not in (200, 201):
            raise RuntimeError("Role write uncertain; reconcile upgrade GET without replay")
    else:
        plan = role_transition_plan(config, state)
        journal = state["roleTransition"]
        if state["phase"] not in ("RoleTransitionRequested", "ConfiguredOidcUnverified"):
            raise ValueError("Role upgrade cannot reuse a removing/removed manifest")
    # Durable Requested intent is a dispatch boundary, even if the old role remains.
    readback = transition_readback(plan["after"], api)
    compare_transition_readbacks(
        journal["beforeReadback"], readback, 2,
        plan["after"]["assets"][2]["body"]["properties"],
    )
    if journal["phase"] == "Verified":
        return state
    state = copy.deepcopy(plan["after"])
    state["roleTransition"] = {**journal, "phase": "Verified", "readback": readback}
    persist(path, state)
    return state


def check(config: dict[str, Any], path: Path, api: Api) -> None:
    state = manifest(config, path)
    if state.get("phase") != "ConfiguredOidcUnverified" or len(state["assets"]) != 4:
        raise ValueError("Owned federation configuration is incomplete")
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is None:
            raise ValueError("Owned federation asset missing")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)
    # This is operator ARM readback, never proof of the actual workflow identity's access.



def failed_bicep_proof(
    config: dict[str, Any], state: dict[str, Any], receipt: dict[str, Any] | None
) -> str:
    """Prove no further creation can occur; never infer this from a CLI exit code."""
    deployment = object_value(state.get("bicepDeployment"))
    identity = state["assets"][0]
    plan = bicep_spec(config, identity["body"]["location"], identity["body"]["tags"]["expiresAt"])
    if (
        state.get("schemaVersion") != 1
        or role_profile(state) != ROLE_PROFILE
        or deployment.get("phase") != "Requested"
        or any(deployment.get(key) != value for key, value in plan["deployment"].items())
        or not re.fullmatch(r"[0-9a-f]{64}", str(deployment.get("sourceSha256", "")))
    ):
        raise ValueError("Failed Bicep deployment binding/journal changed; no cleanup")
    outcome = deployment.get("submissionOutcome")
    if outcome == "NotSubmitted":
        # This marker was durably saved before compilation, and must be replaced
        # by Unknown before dispatch. A missing Azure receipt alone is NOT proof.
        if receipt is not None:
            raise ValueError("Local no-dispatch intent has an Azure deployment; no cleanup")
        if any(asset.get("phase") != "Requested" for asset in state["assets"]) or any(
            key in state for key in ("clientId", "principalId", "tenantId")
        ):
            raise ValueError(
                "Local no-dispatch intent contains created/verified assets; no cleanup"
            )
        return "LocalNoDispatch"
    if outcome not in ("Unknown", "ReturnedSuccess", "ReturnedFailure") or receipt is None:
        raise RuntimeError(
            "Failed Bicep deployment is unknown; terminal proof required for cleanup"
        )
    if not re.fullmatch(r"[0-9a-f]{64}", str(deployment.get("compiledTemplateSha256", ""))):
        raise ValueError("Failed Bicep journal lacks a frozen compiled template; no cleanup")
    status = validate_bicep_receipt(deployment, receipt)
    if status not in ("Failed", "Canceled"):
        raise RuntimeError(
            "Failed Bicep cleanup requires terminal Failed/Canceled, not in-progress/success"
        )
    return "TerminalDeployment"


def failed_bicep_assets(
    state: dict[str, Any], snapshots: list[dict[str, Any] | None], proof: str
) -> list[dict[str, Any]]:
    """Validate the whole set before deletion; never upgrade Requested to Verified."""
    if len(snapshots) != 4 or any(
        asset.get("phase") not in ("Requested", "Verified") for asset in state["assets"]
    ):
        raise ValueError("Incomplete failed Bicep asset intent; no cleanup")
    if proof == "LocalNoDispatch" and any(live is not None for live in snapshots):
        raise ValueError("Unowned asset after local no-dispatch failure; no adoption/delete")
    present = []
    for asset, live in zip(state["assets"], snapshots, strict=True):
        if live is None:
            # Only the independently proven terminal/no-dispatch boundary permits
            # Requested absence, including retries after a lost DELETE response.
            continue
        if asset["kind"] == "assignment":
            if "principalId" not in state:
                raise ValueError(
                    "Owned assignment principal cannot be proved without identity readback"
                )
            asset["body"]["properties"]["principalId"] = state["principalId"]
        validate_asset(asset, live, allow_terminal_failure=True)
        if asset["kind"] == "identity":
            bind_identity(state, live, capture=asset["phase"] == "Requested")
            state["assets"][-1]["body"]["properties"]["principalId"] = state["principalId"]
        present.append(asset)
    return present


def remove_failed_bicep(
    config: dict[str, Any], path: Path, api: Api, state: dict[str, Any]
) -> None:
    """Explicitly authorized cleanup of a terminal or locally undispatched intent."""
    if state.get("phase") not in ("BicepDeploymentRequested", "Removing", "Removed"):
        raise ValueError("Not an incomplete Bicep cleanup state")
    original = copy.deepcopy(state)
    receipt = get_optional(api, deployment_path(object_value(state.get("bicepDeployment"))))
    snapshots = [get_optional(api, resource_path(asset)) for asset in state["assets"]]
    proof = failed_bicep_proof(config, state, receipt)
    journal = state.get("failedBicepCleanup")
    if journal is not None:
        journal = object_value(journal)
        before = manifest_value(config, copy.deepcopy(object_value(journal.get("before"))))
        if (
            journal.get("authorization") != "allow-failed-bicep"
            or journal.get("phase") not in ("Requested", "Removed")
            or before.get("phase") != "BicepDeploymentRequested"
            or "failedBicepCleanup" in before
            or before.get("bicepDeployment") != state["bicepDeployment"]
            or journal.get("proof") != proof
        ):
            raise ValueError("Failed Bicep cleanup history changed; no deletion")
        # The original proof/readbacks remain frozen, even across partial deletion.
        if failed_bicep_proof(config, before, journal.get("deploymentReadback")) != proof:
            raise ValueError("Failed Bicep cleanup proof changed")
        failed_bicep_assets(before, journal.get("assetReadbacks"), proof)
        binding = object_value(journal.get("identityBinding"))
        actual_binding = {
            key: state[key] for key in ("clientId", "principalId", "tenantId") if key in state
        }
        if binding != actual_binding or any(
            before.get(key) != binding.get(key)
            for key in ("clientId", "principalId", "tenantId")
            if key in before
        ):
            raise ValueError("Failed Bicep cleanup identity binding changed")
        identity_readback = journal.get("identityReadback")
        if identity_readback is not None:
            validate_asset(state["assets"][0], identity_readback, allow_terminal_failure=True)
            bind_identity(state, identity_readback)
    elif state.get("phase") != "BicepDeploymentRequested":
        raise ValueError("Missing authorized failed Bicep cleanup journal")
    present = failed_bicep_assets(state, snapshots, proof)
    if journal is None:
        state["failedBicepCleanup"] = {
            "authorization": "allow-failed-bicep",
            "phase": "Requested",
            "before": original,
            "proof": proof,
            "deploymentReadback": receipt,
            "assetReadbacks": snapshots,
            "identityBinding": {},
            "identityReadback": None,
        }
    journal = state["failedBicepCleanup"]
    if not journal["identityBinding"] and "principalId" in state:
        journal["identityBinding"] = {
            key: state[key] for key in ("clientId", "principalId", "tenantId")
        }
        journal["identityReadback"] = snapshots[0]
    state["phase"] = "Removing"
    manifest_value(config, state)
    # Failure evidence and any real identity binding are fsynced before any DELETE.
    persist(path, state)
    for asset in reversed(present):
        status, _ = api.request("DELETE", resource_path(asset))
        if status not in (200, 202, 204):
            raise RuntimeError("Owned failed Bicep deletion uncertain")
        deadline = time.monotonic() + 120
        while get_optional(api, resource_path(asset)) is not None:
            if time.monotonic() >= deadline:
                raise RuntimeError("Owned failed Bicep residual remains")
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    remaining = [get_optional(api, resource_path(asset)) for asset in state["assets"]]
    if any(live is not None for live in remaining):
        raise RuntimeError("Failed Bicep final absence unverified")
    state["phase"] = "Removed"
    state["failedBicepCleanup"]["phase"] = "Removed"
    manifest_value(config, state)
    persist(path, state)


def remove(
    config: dict[str, Any], path: Path, api: Api, *, allow_failed_bicep: bool = False
) -> None:
    state = manifest(config, path)
    if "bicepDeployment" in state and (
        state["bicepDeployment"].get("phase") != "Verified"
        or state.get("phase") not in ("ConfiguredOidcUnverified", "Removing", "Removed")
    ):
        if allow_failed_bicep:
            remove_failed_bicep(config, path, api, state)
            return
        raise ValueError("Bicep deployment incomplete; reconcile deploy-bicep before teardown")
    present = []
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is not None:
            if not asset.get("phase"):
                raise ValueError("Late unowned federation asset; no deletion")
            validate_asset(asset, live)
            if asset["kind"] == "identity":
                bind_identity(state, live, capture=asset["phase"] == "Requested")
            if asset["phase"] == "Requested":
                asset["phase"] = "Verified"
                persist(path, state)
            present.append(asset)
        elif asset.get("phase") == "Requested":
            raise RuntimeError("Uncertain ARM creation; no absence/removal claim")
    state["phase"] = "Removing"
    persist(path, state)
    for asset in reversed(present):
        status, _ = api.request("DELETE", resource_path(asset))
        if status not in (200, 202, 204):
            raise RuntimeError("Owned ARM deletion uncertain")
        deadline = time.monotonic() + 120
        while get_optional(api, resource_path(asset)) is not None:
            if time.monotonic() >= deadline:
                raise RuntimeError("Owned federation residual remains")
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    if any(get_optional(api, resource_path(asset)) is not None for asset in state["assets"]):
        raise RuntimeError("Owned federation final absence unverified")
    state["phase"] = "Removed"
    persist(path, state)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=(
        "spec", "configure", "check", "down", "transition-spec", "transition-subject",
        "role-upgrade-spec", "upgrade-role", "bicep-spec", "deploy-bicep",
    ))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--location")
    parser.add_argument("--expires-at")
    parser.add_argument("--repository-evidence", type=Path)
    parser.add_argument("--allow-failed-bicep", action="store_true",
                        help="Owner-authorized down of proven terminal/no-dispatch Bicep failures")
    args = parser.parse_args()
    if args.allow_failed_bicep and args.operation != "down":
        raise ValueError("--allow-failed-bicep is authorized only with down")
    config = validate_config(json.loads(args.config.read_text()), ready=False)
    if (args.operation in ("spec", "configure", "bicep-spec", "deploy-bicep")
            and not (args.location and args.expires_at)):
        raise ValueError("Identity location and explicit retention expiry are required")
    if args.operation == "spec":
        print(json.dumps(specifications(config, args.location, args.expires_at), indent=2))
        return
    if args.operation == "bicep-spec":
        print(json.dumps(bicep_spec(config, args.location, args.expires_at), indent=2))
        return
    if args.state is None:
        raise ValueError("An ignored owner-only federation manifest is required")
    evidence = (json.loads(args.repository_evidence.read_text(encoding="utf-8"))
                if args.repository_evidence else None)
    if args.operation == "transition-spec":
        state = object_value(json.loads(args.state.read_text(encoding="utf-8")))
        print(json.dumps(subject_transition_spec(config, state, evidence), indent=2))
        return
    if args.operation == "role-upgrade-spec":
        state = object_value(json.loads(args.state.read_text(encoding="utf-8")))
        print(json.dumps(role_upgrade_spec(config, state), indent=2))
        return
    if args.operation == "deploy-bicep":
        repository_binding(config, evidence)
        bicep_spec(config, args.location, args.expires_at)
    api = Api("https://management.azure.com", arm_token(config))
    lock = args.state.with_suffix(".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        if args.operation == "configure":
            configure(config, args.state, api, args.location, args.expires_at, evidence)
        elif args.operation == "deploy-bicep":
            deploy_bicep(config, args.state, api, args.location, args.expires_at, evidence)
        elif args.operation == "check":
            check(config, args.state, api)
        elif args.operation == "transition-subject":
            transition_subject(config, args.state, api, evidence)
        elif args.operation == "upgrade-role":
            upgrade_role(config, args.state, api)
        else:
            remove(config, args.state, api, allow_failed_bicep=args.allow_failed_bicep)
    finally:
        os.close(descriptor)
        lock.unlink()


def arm_token(config: dict[str, Any]) -> str:
    token = subprocess.run(
        [azure_cli_executable(), "account", "get-access-token",
         "--resource", "https://management.azure.com/",
         "--subscription", config["binding"]["subscriptionId"],
         "--query", "accessToken", "--output", "tsv"],
        capture_output=True, text=True, timeout=30, check=False, shell=False,
    )
    if token.returncode or not token.stdout.strip():
        raise RuntimeError("Operator ARM authentication failed; no alternate identity")
    return token.stdout.strip()


if __name__ == "__main__":
    main()
