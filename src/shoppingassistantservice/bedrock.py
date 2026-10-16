"""Amazon Bedrock Converse client (boto3), with the model ID and the timeouts from the environment.

Credentials come from EKS Pod Identity (the pod's role allows bedrock:InvokeModel only, on
this one model: terraform-aws/modules/environment/pod-identity.tf). No key in the image or
the environment.
"""


class BedrockError(Exception):
    """A failed Converse call. `kind` is the metric label: throttled, timeout, access_denied,
    validation or other."""

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


_KINDS = {
    "ThrottlingException": "throttled",
    "ServiceQuotaExceededException": "throttled",
    "ModelTimeoutException": "timeout",
    "AccessDeniedException": "access_denied",
    "ValidationException": "validation",
    "ResourceNotFoundException": "validation",
}


def model_id(base, use_inference_profile):
    """amazon.nova-lite-v1:0, or us.amazon.nova-lite-v1:0 through the US inference profile."""
    if use_inference_profile and not base.startswith("us."):
        return "us." + base
    return base


class BedrockModel:
    def __init__(self, model_id, region, timeout_seconds=15, client=None):
        self.model_id = model_id
        if client is None:
            import boto3  # imported here so the unit tests run without boto3
            from botocore.config import Config
            client = boto3.client("bedrock-runtime", region_name=region, config=Config(
                connect_timeout=3,
                read_timeout=timeout_seconds,
                retries={"max_attempts": 2, "mode": "standard"},
            ))
        self.client = client

    def converse(self, request):
        """request: the Converse arguments without modelId. Returns the response dict."""
        try:
            return self.client.converse(modelId=self.model_id, **request)
        except Exception as err:
            raise BedrockError(classify(err), f"{type(err).__name__}: {err}"[:300]) from err


def classify(err):
    code = getattr(err, "response", {}).get("Error", {}).get("Code", "") if hasattr(err, "response") else ""
    if code in _KINDS:
        return _KINDS[code]
    name = type(err).__name__
    if "Timeout" in name:  # botocore ReadTimeoutError / ConnectTimeoutError
        return "timeout"
    return "other"
