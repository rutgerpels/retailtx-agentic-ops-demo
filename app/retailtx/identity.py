import os
from functools import lru_cache

from azure.identity import ManagedIdentityCredential

ARC_IDENTITY_ENDPOINT = "http://localhost:40342/metadata/identity/oauth2/token"
ARC_IMDS_ENDPOINT = "http://localhost:40342"


def validate_identity(kind: str) -> None:
    if kind not in {"vm", "arc"}:
        raise ValueError("Azure mode requires RETAILTX_IDENTITY=vm or arc")
    forbidden = (
        "AZURE_CLIENT_ID",
        "AZURE_CLIENT_SECRET",
        "AZURE_FEDERATED_TOKEN_FILE",
        "IDENTITY_HEADER",
        "IDENTITY_SERVER_THUMBPRINT",
        "MSI_ENDPOINT",
        "MSI_SECRET",
        "AZURE_POD_IDENTITY_AUTHORITY_HOST",
    )
    if any(os.environ.get(key) for key in forbidden):
        raise ValueError("Only the host system-assigned managed identity is supported")
    if kind == "arc":
        if (
            os.environ.get("IDENTITY_ENDPOINT") != ARC_IDENTITY_ENDPOINT
            or os.environ.get("IMDS_ENDPOINT") != ARC_IMDS_ENDPOINT
        ):
            raise ValueError("Arc identity requires the documented localhost:40342 endpoints")
    elif os.environ.get("IDENTITY_ENDPOINT") or os.environ.get("IMDS_ENDPOINT"):
        raise ValueError("VM identity must use Azure IMDS, not an override endpoint")


@lru_cache(maxsize=2)
def _credential(kind: str) -> ManagedIdentityCredential:
    return ManagedIdentityCredential(connection_timeout=3, read_timeout=5, retry_total=2)


def managed_identity(kind: str) -> ManagedIdentityCredential:
    validate_identity(kind)
    return _credential(kind)
