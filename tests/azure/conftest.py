import os

import pytest
from retailtx.settings import Settings


@pytest.fixture
def azure_env(monkeypatch):
    for key in tuple(os.environ):
        if key.startswith(
            (
                "RETAILTX_",
                "CAP_",
                "ERP_",
                "BROKER_",
                "TLS_",
                "APPLICATIONINSIGHTS_",
                "IDENTITY_",
                "IMDS_",
                "MSI_",
                "AZURE_",
                "PG",
            )
        ):
            monkeypatch.delenv(key)
    values = {
        "RETAILTX_MODE": "azure",
        "RETAILTX_ENVIRONMENT_ID": "demo01",
        "RETAILTX_IDENTITY": "vm",
        "CAP_DB_HOST": "cap-demo01.postgres.database.azure.com",
        "CAP_DB_USER": "cap-runtime",
        "CAP_DB_SSLROOTCERT": "pyproject.toml",
        "BROKER_NAMESPACE": "retailtx-demo01.servicebus.windows.net",
        "CAP_URL": "https://cap.demo01.retailtx.internal:8443",
        "ERP_URL": "https://erp.demo01.retailtx.internal:8443",
        "TLS_CA_FILE": "pyproject.toml",
        "TLS_CERT_FILE": "pyproject.toml",
        "TLS_KEY_FILE": "pyproject.toml",
        "APPLICATIONINSIGHTS_CONNECTION_STRING": (
            "InstrumentationKey=00000000-0000-0000-0000-000000000001;"
            "IngestionEndpoint=https://swedencentral-0.in.applicationinsights.azure.com/"
        ),
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    return values


@pytest.fixture
def settings(azure_env):
    return Settings.from_env()
