"""Offline compiled contract for the standalone Bicep GitHub caller module."""

import copy
import json
import re
import subprocess
import uuid

import pytest

from scripts.github import federation, intake

MODULE = intake.ROOT / "infra" / "github-intake-identity.bicep"
EXPIRY = "2030-01-01T00:00:00Z"
PRINCIPAL = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"


@pytest.fixture(scope="module")
def template():
    # No restore, login, deployment, Azure API calls, or generated repository files.
    result = subprocess.run(
        [
            intake.azure_cli_executable(),
            "bicep",
            "build",
            "--file",
            str(MODULE),
            "--no-restore",
            "--stdout",
        ],
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )
    return json.loads(result.stdout)


@pytest.mark.parametrize("immutable", [False, True])
@pytest.mark.parametrize(
    "owner_token",
    [
        "00000000-0000-0000-0000-000000000000",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    ],
)
def test_python_owned_contract(template, immutable, owner_token):
    config = json.loads((intake.ROOT / "profiles/github/intake.example.json").read_text())
    config["binding"]["ownerToken"] = owner_token
    if not immutable:
        config["oidc"]["subject"] = f"repo:{config['repository']}:environment:sre-github-intake"
    specs = federation.specifications(config, "swedencentral", EXPIRY)
    identity, fic, role, assignment = specs
    group = config["binding"]["agentId"].split("/providers/", 1)[0]
    assert role["id"].split("/")[-1] == str(
        uuid.uuid5(
            uuid.UUID(owner_token),
            "github-intake-role:" + config["binding"]["agentId"],
        )
    )
    assert assignment["id"].split("/")[-1] == str(
        uuid.uuid5(
            uuid.UUID(owner_token),
            "github-intake-assignment:" + identity["id"],
        )
    )

    variables = template["variables"]
    # Freeze the ARM expressions that preserve the Python ID/scope/subject formulas.
    assert variables["identityId"] == (
        "[resourceId(subscription().subscriptionId, split(parameters('agentId'), '/')[4], "
        "'Microsoft.ManagedIdentity/userAssignedIdentities', variables('identityName'))]"
    )
    assert (
        variables["identityName"]
        == "[format('retailtx-github-intake-{0}', parameters('environment'))]"
    )
    assert variables["assignmentId"] == (
        "[format('{0}/providers/Microsoft.Authorization/roleAssignments/{1}', "
        "variables('boundAgentId'), parameters('roleAssignmentName'))]"
    )
    assert variables["allowedAgentIds"] == [
        (
            "[resourceId(subscription().subscriptionId, split(parameters('agentId'), '/')[4], "
            "'Microsoft.App/agents', variables('agentName'))]"
        ),
    ]
    assert variables["boundAgentId"] == (
        "[variables('allowedAgentIds')[indexOf(variables('allowedAgentIds'), pa"
        "rameters('agentId'))]]"
    )
    assert variables["boundSubject"] == (
        "[variables('allowedSubjects')[indexOf(variables('allowedSubjects'), pa"
        "rameters('verifiedOidcSubject'))]]"
    )
    assert variables["allowedSubjects"] == [
        "[variables('classicSubject')]",
        "[variables('immutableSubject')]",
    ]
    assert (
        variables["classicSubject"]
        == "[format('repo:{0}:environment:sre-github-intake', parameters('repository'))]"
    )
    assert variables["immutableSubject"] == (
        "[format('repo:{0}@{1}/{2}@{3}:environment:sre-github-intake', "
        "split(parameters('repository'), '/')[0], parameters('repositoryOwnerId'), "
        "split(parameters('repository'), '/')[1], parameters('repositoryId'))]"
    )

    values = {
        "[parameters('environment')]": config["environment"],
        "[parameters('location')]": "swedencentral",
        "[parameters('ownerToken')]": owner_token,
        "[parameters('expiresAt')]": EXPIRY,
        "[variables('identityId')]": subscription_resource_id(variables["identityId"], config),
        "[variables('federationId')]": fic["id"],
        "[variables('assignmentId')]": assignment["id"],
        "[variables('boundSubject')]": config["oidc"]["subject"],
        (
            "[subscriptionResourceId('Microsoft.Resources/resourceGroups', split(pa"
            "rameters('agentId'), '/')[4])]"
        ): group,
        (
            "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', par"
            "ameters('roleDefinitionName'))]"
        ): role["id"],
        (
            "[format('RetailTx GitHub intake {0} {1}', parameters('environment'), p"
            "arameters('ownerToken'))]"
        ): role["body"]["properties"]["roleName"],
        "[format('Proposal-only GitHub intake; ownerToken={0}', parameters('ownerToken'))]": role[
            "body"
        ]["properties"]["description"],
    }

    def resolve(value):
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        if isinstance(value, list):
            return [resolve(item) for item in value]
        if isinstance(value, str) and value.startswith("["):
            if value in values:
                return values[value]
            if value.startswith("[variables('") and value.endswith("')]"):
                return resolve(variables[value[12:-3]])
            if value.startswith("[reference(") and value.endswith(".outputs.principalId.value]"):
                return PRINCIPAL  # Only the Azure-generated principal is mocked.
            pytest.fail(f"Unrecognized contract expression: {value}")
        return value

    actual = resolve(template["outputs"]["federationAssets"]["value"])
    expected = copy.deepcopy(specs)
    expected[-1]["body"]["properties"]["principalId"] = PRINCIPAL
    assert actual == expected
    # The handoff remains consumable by the existing check/teardown parser.
    state = {
        "schemaVersion": 1,
        "ownerToken": owner_token,
        "configHash": federation.binding_hash(config),
        "roleProfile": "investigator-read-v1",
        "phase": "ConfiguredOidcUnverified",
        "principalId": PRINCIPAL,
        "assets": [{**asset, "phase": "Verified"} for asset in actual],
    }
    assert federation.manifest_value(config, state) == state


def test_actual_resources_and_inner_expressions(template):
    assert template["$schema"].endswith("subscriptionDeploymentTemplate.json#")
    assert all("defaultValue" not in item for item in template["parameters"].values())
    assert set(template["parameters"]) == {
        "environment",
        "location",
        "ownerToken",
        "agentId",
        "repository",
        "repositoryId",
        "repositoryOwnerId",
        "verifiedOidcSubject",
        "expiresAt",
        "roleDefinitionName",
        "roleAssignmentName",
    }
    resources = template["resources"]
    assert len(resources) == 3  # AVM deployment, subscription role, RG assignment deployment.
    role = next(
        item for item in resources if item["type"] == "Microsoft.Authorization/roleDefinitions"
    )
    assert role["name"] == "[parameters('roleDefinitionName')]"
    assert role["properties"] == "[variables('roleProperties')]"
    assert role["apiVersion"] == "2022-04-01"
    identity = next(item for item in resources if "identity" in item["name"])
    params = identity["properties"]["parameters"]
    assert params["enableTelemetry"]["value"] is False
    assert params["tags"]["value"] == "[variables('identityTags')]"
    assert params["federatedIdentityCredentials"]["value"] == [
        {
            "name": "github-intake",
            "issuer": "[variables('federationProperties').issuer]",
            "subject": "[variables('federationProperties').subject]",
            "audiences": "[variables('federationProperties').audiences]",
        }
    ]
    inner_identity = identity["properties"]["template"]
    assert inner_identity["metadata"]["_generator"]["name"] == "bicep"
    grant = next(item for item in resources if "assignment" in item["name"])
    assert grant["resourceGroup"] == "[split(parameters('agentId'), '/')[4]]"
    assert grant["properties"]["expressionEvaluationOptions"] == {"scope": "inner"}
    assert grant["properties"]["mode"] == "Incremental"
    assert len(grant["dependsOn"]) == 2
    expression = grant["properties"]["template"]
    assert expression.startswith("[json('") and expression.endswith("')]")
    nested = json.loads(expression[7:-3].replace("''", "'"))
    assert nested["resources"] == [
        {
            "type": "Microsoft.Authorization/roleAssignments",
            "apiVersion": "2022-04-01",
            "name": "[parameters('roleAssignmentName')]",
            "scope": "[parameters('agentId')]",
            "properties": {
                "roleDefinitionId": "[parameters('roleDefinitionId')]",
                "principalType": "ServicePrincipal",
                "principalId": "[parameters('principalId')]",
            },
        }
    ]
    source = MODULE.read_text()
    assert "br/public:avm/res/managed-identity/user-assigned-identity:0.6.0" in source
    assert "guid(" not in source.replace("// Bicep guid()", "// Bicep GUID")
    assert "Standard User" not in source
    assert template["outputs"]["roleProfile"]["value"] == "investigator-read-v1"


def subscription_resource_id(expression, config):
    """Small offline ARM-overload semantics guard, NOT Azure service validation.

    In subscription deployments a three-argument call's first value denotes a
    subscription, not an implicit RG. These RG-bound resources need four args.
    Parse the actual compiled call rather than substituting its intended ID.
    """
    assert expression.startswith("[resourceId(") and expression.endswith(")]")
    call = expression.removeprefix("[resourceId(").removesuffix(")]")
    arguments = []
    start = depth = 0
    quoted = False
    for index, char in enumerate(call):
        if char == "'":
            quoted = not quoted
        elif not quoted:
            if char in "([":
                depth += 1
            elif char in ")]":
                depth -= 1
            elif char == "," and depth == 0:
                arguments.append(call[start:index].strip())
                start = index + 1
    arguments.append(call[start:].strip())
    values = {
        "subscription().subscriptionId": config["binding"]["subscriptionId"],
        "split(parameters('agentId'), '/')[4]": config["binding"]["agentId"].split("/")[4],
        "variables('identityName')": "retailtx-github-intake-" + config["environment"],
        "variables('agentName')": config["binding"]["agentId"].rsplit("/", 1)[1],
    }
    resolved = []
    for argument in arguments:
        if argument in values:
            resolved.append(values[argument])
        else:
            literal = re.fullmatch(r"'([^']+)'", argument)
            assert literal is not None, f"Unrecognized compiled resourceId argument: {argument}"
            resolved.append(literal[1])
    try:
        uuid.UUID(resolved[0])
    except ValueError as error:
        raise ValueError("InvalidTemplate: value is not a valid subscription identifier") from error
    if len(resolved) != 4:
        raise ValueError("Explicit subscription + RG resourceId overload required")
    subscription_id, group, resource_type, name = resolved
    return (
        f"/subscriptions/{subscription_id}/resourceGroups/{group}/providers/{resource_type}/{name}"
    )


@pytest.mark.parametrize(
    "group",
    [
        "rg-retailtx-guest-demo01-swedencentral",
        "11111111-1111-1111-1111-111111111111",
    ],
)
def test_compiled_subscription_scope_resource_id_semantics(template, group):
    config = json.loads((intake.ROOT / "profiles/github/intake.example.json").read_text())
    original_agent = config["binding"]["agentId"]
    pieces = original_agent.split("/")
    pieces[4] = group
    config["binding"]["agentId"] = "/".join(pieces)
    identity = federation.specifications(config, "swedencentral", EXPIRY)[0]
    assert subscription_resource_id(template["variables"]["identityId"], config) == identity["id"]
    assert (
        subscription_resource_id(template["variables"]["allowedAgentIds"][0], config)
        == config["binding"]["agentId"]
    )


def test_previous_rg_only_overload_reproduces_subscription_identifier_validation_error(template):
    config = json.loads((intake.ROOT / "profiles/github/intake.example.json").read_text())
    # This mutation reproduces the old emitted template, including the agent gate.
    for expression in (
        template["variables"]["identityId"],
        template["variables"]["allowedAgentIds"][0],
    ):
        ambiguous = expression.replace("subscription().subscriptionId, ", "", 1)
        with pytest.raises(ValueError, match="not a valid subscription identifier"):
            subscription_resource_id(ambiguous, config)
