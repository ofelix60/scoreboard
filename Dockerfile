# Pin the base image for reproducible builds.
ARG PY=python:3.12.14-slim-trixie@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

# Build stage: uv and dependency installation stay out of the final image.
FROM ${PY} AS builder
COPY --from=ghcr.io/astral-sh/uv:0.9.7 /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PYTHONUNBUFFERED=1
WORKDIR /app

# Keep dependency layer cacheable when source code changes.
COPY pyproject.toml uv.lock ./
# Install production dependencies into the venv; don't install the project yet.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

# Runtime stage: start fresh and copy only what the app needs.
FROM ${PY}
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"
# Run as non-root.
RUN useradd -u 10001 -m appuser
WORKDIR /app
# Reuse the venv from the builder. Both stages use the same Python base.
COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --chown=10001:10001 . ./
USER 10001
EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=2s --start-period=10s --retries=3 \
  CMD ["python", "-c", \
       "import socket,urllib.request; \
        ip=socket.gethostbyname(socket.gethostname()); \
        urllib.request.urlopen('http://'+ip+':8000/readyz', timeout=1.5).read()"]
# Explicitly use the venv's Python to run uvicorn.
CMD ["/app/.venv/bin/python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0"]