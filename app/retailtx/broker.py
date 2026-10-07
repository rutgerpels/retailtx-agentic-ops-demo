from azure.servicebus import ServiceBusClient

from retailtx.settings import Settings

QUEUE = "IDOC_POSTING"


def client(settings: Settings) -> ServiceBusClient:
    return ServiceBusClient.from_connection_string(
        settings.emulator_connection, retry_total=2, retry_backoff_max=3
    )
