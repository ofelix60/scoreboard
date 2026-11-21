import ipaddress
import logging
import os
import socket
import sys
from urllib.parse import urlsplit, urlunsplit

import structlog
from structlog.typing import Processor

from build import BUILD_TIME, GIT_SHA
from sensitive_keys import SENSITIVE_KEYS

ENV = os.getenv("ENV", "development")
HOSTNAME = socket.gethostname()
SERVICE = os.getenv("SERVICE", "scoreboard")


def group_error(logger, method_name, event_dict):
    exc = event_dict.pop("exc", None)
    if exc is not None:
        err = event_dict.setdefault("error", {})
        err.setdefault("message", str(exc))
        err["type"] = type(exc).__name__
        fields, cur = {}, exc
        while isinstance(cur, BaseException):  # walk the __cause__ chain
            fields.update(getattr(cur, "fields", {}))
            cur = cur.__cause__
        err.update(fields)
    return event_dict


def add_static_context(logger, method_name, event_dict):
    event_dict["service"] = SERVICE
    event_dict["env"] = ENV
    event_dict["hostname"] = HOSTNAME
    event_dict["git_sha"] = GIT_SHA
    event_dict["build_time"] = BUILD_TIME
    return event_dict


def redact_ip(addr: str) -> str:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return addr
    if ip.version == 4:
        return ".".join(str(ip).split(".")[:3] + ["x"])
    # IPv6: keep /48, zero the rest
    net = ipaddress.ip_network(f"{ip}/48", strict=False)
    return str(net.network_address)


def safe_dsn(dsn: str) -> str:
    try:
        parts = urlsplit(dsn)
    except ValueError:
        return "invalid dsn"
    if parts.password is None:
        return dsn
    netloc = f"{parts.username}:***@{parts.hostname}"
    if parts.port:
        netloc += f":{parts.port}"
    return urlunsplit(parts._replace(netloc=netloc))


def redact(logger, method_name, event_dict):
    for key in list(event_dict):
        if key.lower() in SENSITIVE_KEYS:
            event_dict[key] = "[REDACTED]"
        elif isinstance(event_dict[key], str) and "://" in event_dict[key]:
            event_dict[key] = safe_dsn(event_dict[key])
    return event_dict


# Division of labor: structlog shapes each log (key/value fields + rendering),
# while stdlib logging handles routing (handlers, levels, buffering). The two
# connect at ProcessorFormatter below.

# Processors that enrich every record with level, logger name, and an ISO timestamp.
timestamper = structlog.processors.TimeStamper(fmt="iso", utc=True)
pre_chain: list[Processor] = [
    structlog.contextvars.merge_contextvars,
    add_static_context,
    structlog.stdlib.add_log_level,
    structlog.stdlib.add_logger_name,
    timestamper,
    group_error,
    redact,
]


def initialize_logging() -> structlog.BoundLogger:

    # Console output. foreign_pre_chain runs these processors over records from
    # libraries that don't use structlog (uvicorn, httpx, asyncio) so their logs
    # match the format of ours.
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG)
    renderer: list[Processor]
    if sys.stdout.isatty():
        renderer = [structlog.dev.ConsoleRenderer()]
    else:
        renderer = [
            structlog.processors.ExceptionRenderer(
                structlog.tracebacks.ExceptionDictTransformer(
                    show_locals=False,
                    max_frames=10,
                )
            ),
            structlog.processors.JSONRenderer(),
        ]

    console.setFormatter(
        structlog.stdlib.ProcessorFormatter(
            processors=[
                structlog.stdlib.ProcessorFormatter.remove_processors_meta,
                *renderer,
            ],
            foreign_pre_chain=pre_chain,
        )
    )

    # Attach handlers to the root logger so third-party records reach them too —
    # those propagate to root and never to a named application logger.
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    root.addHandler(console)

    # Silence httpx's per-request INFO logs; keep its warnings and errors.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(
        logging.WARNING
    )  # TLS/connection lifecycle noise

    # Configures the call-site end: how logger.info("event", key=val) is processed.
    # wrap_for_formatter passes the structlog record into stdlib's handler pipeline
    # above, so both app and third-party logs share one output path.
    structlog.configure(
        processors=pre_chain + [structlog.stdlib.ProcessorFormatter.wrap_for_formatter],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    logger = structlog.get_logger("scoreboard")
    logger.info("logging configured")

    return logger
