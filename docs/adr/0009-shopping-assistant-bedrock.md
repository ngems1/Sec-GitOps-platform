# 0009: AI shopping assistant on Amazon Bedrock (Nova Lite, Converse, read-only tools)

Status: accepted (Phase 2, AI shopping assistant). Date: 2026-10-16.

## Context

Phase 2 adds a shopping assistant: a shopper asks a question about the products ("a gift under
$30 for a coffee lover?") and gets a short answer grounded on the real catalog. Constraints:

- **No model access by hand.** The console user has no Bedrock permissions
  (`bedrock:ListFoundationModels` is denied) and the "Model access" page is retired: serverless
  models are enabled on their first invoke. Anthropic models also need a one-time use-case form,
  and models sold through AWS Marketplace need an identity with Marketplace permissions for the
  first invoke. Everything must work from the app's own Pod Identity role and the workflows.
- **Read-only, cheap, safe.** The assistant may only read the catalog, never write; its cost must
  be capped per request and per day; no personal data may reach the model.
- **Small catalog.** About ten products, served by productcatalogservice (gRPC
  `ListProducts`, `GetProduct`, `SearchProducts`).
- **Same delivery as the rest:** Helm chart, Argo CD (dev from `main`, prod from `env/prod`),
  Prometheus metrics, the frontend canary (ADR 0008).

## Options considered

1. **Claude on Bedrock** through the Anthropic SDK's Bedrock client.
   - Strong tool use and instruction following.
   - Needs the Anthropic use-case form and a Marketplace-capable first invoke, which nobody can
     do with today's access. Not the default now.
2. **Amazon Nova Lite through the Bedrock Converse API** (boto3 `bedrock-runtime`).
   - Amazon's own model: no use-case form, no Marketplace subscription; the Pod Identity role's
     first `Converse` call enables it. Tool use is supported. A fraction of a cent per question.
   - Converse is the same request shape for Nova and Claude, so the model is a configuration
     value, not code.
3. **Retrieval (embeddings + vector database).**
   - Needed for large catalogs; here it adds a store, an index job and cost for ten products.
4. **Chat widget on every page** vs **a dedicated `/assistant` page.**
   - A page is server-side rendered, needs no client state or streaming, and is easy to demo and
     to switch off.

## Decision

Option 2, with read-only tools and a dedicated page.

- **Service:** `shoppingassistantservice`, Python, HTTP/JSON on the cluster network (no change
  to `protos/demo.proto`). One request = one question (at most 500 characters) and the shopper's
  currency, nothing else.
- **Model:** **Amazon Nova Lite, model ID `amazon.nova-lite-v1:0`**, called directly in
  `us-east-1` (on-demand, no inference profile). If AWS answers that on-demand is not supported
  for it, the values switch to the US cross-region inference profile **`us.amazon.nova-lite-v1:0`**
  (`model.useInferenceProfile: true`), with no code change. Model ID, profile flag, `maxTokens`
  (600) and `temperature` (0.2) are Helm values; Terraform reads the same model ID for the IAM
  policy, and CI checks they match. Moving to a Claude model later is a values change plus the
  one-time use-case form and Marketplace first invoke, done by an admin identity (not the app's).
- **Grounding:** a tool loop of at most 3 steps over two read-only tools, `search_products(query)`
  and `get_product(id)`, both calling productcatalogservice. Prices and descriptions come only
  from tool results; anything else is "I don't know". No vector database.
- **IAM (Pod Identity, one role per environment, namespace-tag condition as for the other
  services):** `bedrock:InvokeModel` (which authorizes `Converse`; there is no separate
  `bedrock:Converse` action) on exactly
  `arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-lite-v1:0`. With the inference profile:
  also `arn:aws:bedrock:us-east-1:<account-id>:inference-profile/us.amazon.nova-lite-v1:0` and the
  foundation-model ARN in each region the US profile routes to (us-east-1, us-east-2, us-west-2),
  those only through the profile (`bedrock:InferenceProfileArn` condition). No `bedrock:List*`,
  no Marketplace permission, no streaming action.
- **Guardrails** (DESIGN section 3.7):
  - prompt injection: fixed system prompt; user text only in the user turn; tool results are data;
    no tools that write, no web or code tools; answers rendered as escaped plain text; product
    links only to IDs that exist in the catalog;
  - cost: `maxTokens` 600, at most 3 tool steps, 15 s timeout, one SDK retry; per-session rate
    limit (about 10 questions a minute) and at most 2 concurrent model calls per pod; a daily
    question cap after which the assistant answers "paused for today"; an AWS Budget with a daily
    alert (`terraform-bootstrap/`, account-level), which alerts but does not stop spending;
  - no personal data: no session ID, cart, email or address is sent; email- and card-like strings
    are masked; prompts are not logged in full; Bedrock invocation logging stays off;
  - network: ingress from the frontend and Prometheus only; egress to DNS, productcatalogservice
    and TCP 443 (the VPC CNI cannot filter by host name; a Bedrock VPC endpoint is a later option).
- **Readiness:** at start the service makes a one-token `Converse` call with its own credentials;
  the pod is Ready only if it succeeds, and the Bedrock error is logged if not.
  > **Note 2026-10-18:** changed. Readiness no longer depends on Bedrock: a slow, throttled or
  > unavailable Bedrock made the pod unready, which failed `argocd-wait` and the whole deploy. Both
  > probes now check only the assistant's own HTTP server (`/readyz` turns 503 at shutdown). The
  > start-up `Converse` call stays as a diagnostic: the log line and the metric
  > `assistant_bedrock_check_ok` (was `assistant_ready`). With Bedrock down, questions get the
  > "error" outcome (HTTP 502, a short answer).
- **Metrics** (Prometheus): requests by outcome (answered, refused, rate limited, paused, error),
  latency histogram, Bedrock errors by type, tokens by direction (from the `usage` of each
  response), tool calls by tool. A Grafana row on the Boutique dashboard.
- **Delivery:** Helm values `shoppingAssistant.create` false by default, true in dev only; the
  frontend shows the `/assistant` link and page only when it is on. Prod stays off until the
  feature is tested (after the Monday demo), then one values change reaches prod through the
  approved `env/prod` promotion. The browse-only loadgenerator never calls the assistant.
- **No permission-boundary change:** the deploy role only creates the role (its boundary allows
  `iam:*`); the model ARN is written in Terraform (no Bedrock data source, so no Bedrock read
  rights for the CI roles). The AWS Budget is created by the bootstrap role.

## Consequences

- Cost: about 5,000 input and 300 output tokens per question, roughly USD 0.0004 with Nova Lite
  (about USD 0.06 / 0.24 per million tokens in us-east-1, to confirm with AWS pricing); a 200-question
  demo day stays under USD 0.10. The daily cap bounds the worst case.
- Nova Lite answers less fluently than a large model and may need a tighter prompt and tool
  descriptions; the model is one values change away.
- A new image, ECR repository, Pod Identity role and chart templates to maintain; one more
  service in the CI and deploy lists.
- The AI incident assistant (after Phase 2) reuses this Bedrock base: client, limits, metrics.

## Revisit when

- The use-case form and a Marketplace first invoke are possible: evaluate a Claude model on the
  same Converse path (values change).
- The catalog grows beyond what tool calls can search well: add retrieval.
- Egress must be locked to Bedrock: add a Bedrock VPC interface endpoint (about USD 7 per AZ per
  month).
