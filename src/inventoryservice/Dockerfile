# inventoryservice: small Python service, no compiler needed
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --from=builder /install /usr/local
COPY inventory.py server.py tracing.py ./
# Runs as a non-root user; works with readOnlyRootFilesystem (nothing is written to disk)
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
