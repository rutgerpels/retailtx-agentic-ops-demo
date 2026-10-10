"""Lease-serialized scenario state stored in the private coordination blob."""

from __future__ import annotations

import json
import re
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Iterator, Protocol

STORAGE_ACCOUNT_PATTERN = re.compile(r"^[a-z0-9]{3,24}$")
CONTAINER_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$")
BLOB_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,254}\.json$")
LEASE_SECONDS = 60


class CoordinationError(RuntimeError):
    """The durable scenario coordination state could not be safely accessed."""


class LeaseSessionProtocol(Protocol):
    state: dict[str, Any]
    etag: str

    def renew(self) -> None: ...

    def save(self, state: dict[str, Any]) -> None: ...


class CoordinationStore(Protocol):
    def initialize(self, initial_state: dict[str, Any]) -> dict[str, Any]: ...

    def locked(self) -> Any: ...


@dataclass
class BlobLeaseSession:
    blob: Any
    lease: Any
    state: dict[str, Any]
    etag: str

    def renew(self) -> None:
        self.lease.renew()

    def save(self, state: dict[str, Any]) -> None:
        from azure.core import MatchConditions

        if not isinstance(state, dict):
            raise CoordinationError("Coordination state must be a JSON object.")
        try:
            self.blob.upload_blob(
                json.dumps(state, sort_keys=True, separators=(",", ":")),
                overwrite=True,
                etag=self.etag,
                match_condition=MatchConditions.IfNotModified,
                lease=self.lease.id,
                timeout=10,
            )
            properties = self.blob.get_blob_properties(
                lease=self.lease.id,
                timeout=10,
            )
        except Exception as error:
            raise CoordinationError(
                "Coordination blob conditional update or ETag readback failed."
            ) from error
        next_etag = getattr(properties, "etag", None)
        if not isinstance(next_etag, str) or not next_etag:
            raise CoordinationError("Coordination blob returned no ETag after update.")
        self.state = state
        self.etag = next_etag


class BlobCoordinationStore:
    """Azure Blob Storage adapter using a real finite lease and ETag condition."""

    def __init__(self, blob: Any):
        self._blob = blob

    @classmethod
    def from_managed_identity(
        cls,
        *,
        storage_account_name: str,
        container_name: str,
        blob_name: str,
        credential: Any,
    ) -> BlobCoordinationStore:
        if not STORAGE_ACCOUNT_PATTERN.fullmatch(storage_account_name):
            raise CoordinationError("Coordination storage account name is invalid.")
        if not CONTAINER_PATTERN.fullmatch(container_name):
            raise CoordinationError("Coordination container name is invalid.")
        if not BLOB_PATTERN.fullmatch(blob_name) or ".." in blob_name.split("/"):
            raise CoordinationError("Coordination blob name is invalid.")

        from azure.storage.blob import BlobServiceClient

        service = BlobServiceClient(
            f"https://{storage_account_name}.blob.core.windows.net",
            credential=credential,
            retry_total=0,
            connection_timeout=10,
            read_timeout=10,
        )
        container = service.get_container_client(container_name)
        return cls(container.get_blob_client(blob_name))

    def initialize(self, initial_state: dict[str, Any]) -> dict[str, Any]:
        try:
            properties = self._blob.get_blob_properties(timeout=10)
        except Exception as error:
            if getattr(error, "status_code", None) != 404:
                raise CoordinationError(
                    "Coordination blob could not be read during initialization."
                ) from error
            try:
                self._blob.upload_blob(
                    json.dumps(initial_state, sort_keys=True, separators=(",", ":")),
                    overwrite=False,
                    timeout=10,
                )
            except Exception as create_error:
                if getattr(create_error, "status_code", None) != 409:
                    raise CoordinationError(
                        "Coordination blob initialization failed."
                    ) from create_error
        with self.locked() as session:
            return dict(session.state)

    @contextmanager
    def locked(self) -> Iterator[BlobLeaseSession]:
        lease = None
        try:
            lease = self._blob.acquire_lease(lease_duration=LEASE_SECONDS, timeout=10)
            downloader = self._blob.download_blob(lease=lease.id, timeout=10)
            value = json.loads(downloader.readall())
            properties = self._blob.get_blob_properties(lease=lease.id, timeout=10)
        except Exception as error:
            if lease is not None:
                try:
                    lease.release()
                except Exception:
                    pass
            raise CoordinationError(
                "Could not acquire the coordination lease and read its state."
            ) from error
        etag = getattr(properties, "etag", None)
        if not isinstance(value, dict) or not isinstance(etag, str) or not etag:
            try:
                lease.release()
            except Exception:
                pass
            raise CoordinationError("Coordination blob state or ETag is invalid.")
        session = BlobLeaseSession(self._blob, lease, value, etag)
        try:
            yield session
        finally:
            try:
                lease.release()
            except Exception as error:
                raise CoordinationError(
                    "Coordination lease release could not be confirmed."
                ) from error
