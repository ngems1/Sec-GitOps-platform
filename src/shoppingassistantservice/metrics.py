"""Prometheus metrics of the shopping assistant (scraped on /metrics, Grafana row in PR (e))."""
from prometheus_client import Counter, Gauge, Histogram

REQUESTS = Counter("assistant_requests_total", "Questions by outcome", ["outcome"])
DURATION = Histogram("assistant_request_duration_seconds", "Time to answer a question",
                     buckets=(0.25, 0.5, 1, 2, 3, 5, 8, 12, 15, 20, 30))
BEDROCK_ERRORS = Counter("assistant_bedrock_errors_total", "Failed Bedrock calls by type", ["type"])
TOKENS = Counter("assistant_tokens_total", "Bedrock tokens by direction", ["direction"])
TOOL_CALLS = Counter("assistant_tool_calls_total", "Catalog tool calls by tool", ["tool"])
READY = Gauge("assistant_ready", "1 when the startup Bedrock check passed")
DAILY_USED = Gauge("assistant_daily_questions_used", "Questions used today in this pod")
DAILY_CAP = Gauge("assistant_daily_question_cap", "Daily question cap of this pod")

KNOWN_TOOLS = {"list_products", "search_products", "get_product"}


class PrometheusMetrics:
    def count(self, name, **labels):
        if name == "request":
            REQUESTS.labels(labels["outcome"]).inc()
        elif name == "bedrock_error":
            BEDROCK_ERRORS.labels(labels["type"]).inc()
        elif name == "tool_call":
            # the tool name comes from the model: bounded so it cannot create new series
            TOOL_CALLS.labels(labels["tool"] if labels["tool"] in KNOWN_TOOLS else "unknown").inc()

    def add_tokens(self, direction, n):
        if n:
            TOKENS.labels(direction).inc(n)
