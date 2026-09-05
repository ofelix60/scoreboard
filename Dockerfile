# slim py.. smaller, safer, faster
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

COPY . ./

ENV PATH="/app/.venv/bin:$PATH"

RUN useradd -u 10001 -m appuser
USER appuser


EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0"]