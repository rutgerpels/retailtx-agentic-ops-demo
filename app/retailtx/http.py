from collections.abc import Awaitable, Callable
from time import perf_counter

import httpx
import psycopg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from retailtx.contracts import Conflict, EvidenceUnavailable
from retailtx.telemetry import SpanKind, event, propagator, tracer


class BodyLimit:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH"}:
            await self.app(scope, receive, send)
            return
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > 8192:
                event("request.rejected", reason="BodyTooLarge")
                await JSONResponse({"detail": "Request body exceeds 8192 bytes"}, 413)(
                    scope, receive, send
                )
                return
            if not message.get("more_body", False):
                break
        delivered = False

        async def bounded_receive() -> Message:
            nonlocal delivered
            if delivered:
                return await receive()
            delivered = True
            return {"type": "http.request", "body": bytes(body), "more_body": False}

        await self.app(scope, bounded_receive, send)


def setup(app: FastAPI) -> None:
    app.add_middleware(BodyLimit)

    @app.middleware("http")
    async def trace_request(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        start = perf_counter()
        # Route names, rather than SKU/transaction IDs, stay out of span names.
        with tracer.start_as_current_span(
            f"{request.method} request",
            context=propagator.extract(dict(request.headers)),
            kind=SpanKind.SERVER,
            record_exception=False,
            set_status_on_exception=False,
        ) as span:
            response = await call_next(request)
            route = request.scope.get("route")
            path = getattr(route, "path", "unmatched")
            span.update_name(f"{request.method} {path}")
            span.set_attribute("http.response.status_code", response.status_code)
            span.set_attribute("http.route", path)
            event(
                "http.request",
                route=path,
                method=request.method,
                status=response.status_code,
                duration_ms=round((perf_counter() - start) * 1000, 3),
            )
            return response

    @app.exception_handler(Conflict)
    async def conflict_handler(request: Request, exc: Conflict) -> JSONResponse:
        event("request.conflict", error=type(exc).__name__)
        return JSONResponse(status_code=409, content={"detail": str(exc)})

    async def dependency_handler(request: Request, exc: Exception) -> JSONResponse:
        event("dependency.unavailable", error=type(exc).__name__)
        return JSONResponse(
            status_code=503, content={"detail": "Dependency unavailable; retry safely"}
        )

    app.add_exception_handler(psycopg.Error, dependency_handler)
    app.add_exception_handler(httpx.HTTPError, dependency_handler)
    app.add_exception_handler(EvidenceUnavailable, dependency_handler)

    @app.exception_handler(RequestValidationError)
    async def validation_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
        event("request.rejected", reason="InvalidContract")
        return JSONResponse(status_code=422, content={"detail": "Invalid request contract"})
