# slim py.. smaller, safer, faster
FROM python:3.12-slim
WORKDIR /app

RUN useradd -u 10001 -m appuser
USER appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0"]