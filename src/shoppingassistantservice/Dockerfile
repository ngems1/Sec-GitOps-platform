# shoppingassistantservice: the AI shopping assistant (ADR 0009). Slim image, non-root,
# works with a read-only root filesystem (no file written at runtime).
FROM python:3.11-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --from=builder /install /usr/local
COPY assistant.py bedrock.py catalog.py metrics.py server.py tracing.py demo_pb2.py demo_pb2_grpc.py ./
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
