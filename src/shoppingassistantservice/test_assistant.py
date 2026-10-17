"""Unit tests with a fake Bedrock and a fake catalog (no AWS, no network). CatalogCodeTest needs the
pinned requirements installed: it fails if demo_pb2*.py and the protobuf / grpcio runtime do not match."""
import contextlib
import datetime
import unittest

import assistant as core
import bedrock

MUG = {"id": "6E92ZMYYFZ", "name": "Mug", "description": "A simple mug with a mustard interior.",
       "picture": "/static/img/products/mug.jpg",
       "price_usd": {"currency_code": "USD", "units": 8, "nanos": 990000000}, "categories": ["kitchen"]}
JAR = {"id": "9SIQT8TOJO", "name": "Bamboo Glass Jar", "description": "This bamboo glass jar can hold 57 oz.",
       "picture": "/static/img/products/bamboo-glass-jar.jpg",
       "price_usd": {"currency_code": "USD", "units": 5, "nanos": 490000000}, "categories": ["kitchen"]}


class FakeCatalog:
    def __init__(self, products=(MUG, JAR)):
        self.products = {p["id"]: p for p in products}
        self.searches = []

    def list_products(self):
        return list(self.products.values())

    def search(self, query):
        self.searches.append(query)
        return [p for p in self.products.values() if query.lower() in (p["name"] + p["description"]).lower()]

    def get(self, product_id):
        return self.products.get(product_id)

    def product_ids(self):
        return set(self.products)


def tool_use(name, args, use_id="t1"):
    return {"stopReason": "tool_use", "usage": {"inputTokens": 100, "outputTokens": 10},
            "output": {"message": {"role": "assistant", "content": [
                {"toolUse": {"toolUseId": use_id, "name": name, "input": args}}]}}}


def final(text):
    return {"stopReason": "end_turn", "usage": {"inputTokens": 200, "outputTokens": 30},
            "output": {"message": {"role": "assistant", "content": [{"text": text}]}}}


class FakeModel:
    """Returns the scripted responses in order and records every request."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def converse(self, request):
        self.requests.append(request)
        item = self.responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class FakeMetrics:
    def __init__(self):
        self.counts = []
        self.tokens = {"input": 0, "output": 0}

    def count(self, name, **labels):
        self.counts.append((name, labels))

    def add_tokens(self, direction, n):
        self.tokens[direction] += n


def make(model, catalog=None, **kw):
    return core.Assistant(model, catalog or FakeCatalog(), metrics=kw.pop("metrics", FakeMetrics()), **kw)


class GroundedAnswerTest(unittest.TestCase):
    def test_tool_then_answer_with_validated_ids(self):
        model = FakeModel(tool_use("search_products", {"query": "mug"}),
                          final("The Mug [6E92ZMYYFZ] costs 8.99 USD. Also see [FAKE123456]."))
        metrics = FakeMetrics()
        catalog = FakeCatalog()
        out = make(model, catalog, metrics=metrics).ask("Do you sell a mug?", "EUR", "session-1")

        self.assertEqual(out["outcome"], "answered")
        self.assertEqual(out["products"], [{"id": "6E92ZMYYFZ", "name": "Mug"}])  # the invented ID is dropped
        self.assertEqual(out["answer"], "The Mug [6E92ZMYYFZ] costs 8.99 USD. Also see.")  # and removed from the text
        self.assertEqual(catalog.searches, ["mug"])
        self.assertEqual(metrics.tokens, {"input": 300, "output": 40})
        self.assertIn(("request", {"outcome": "answered"}), metrics.counts)
        self.assertIn(("tool_call", {"tool": "search_products"}), metrics.counts)

        # the second call carries the tool result: the product as the model may see it
        result = model.requests[1]["messages"][2]["content"][0]["toolResult"]
        self.assertEqual(result["status"], "success")
        seen = result["content"][0]["json"]["products"][0]
        self.assertEqual(seen["price_usd"], "8.99 USD")
        self.assertNotIn("picture", seen)

    def test_request_shape(self):
        model = FakeModel(final("Hello."))
        make(model).ask("hi", "EUR")
        req = model.requests[0]
        self.assertNotIn("modelId", req)  # added by BedrockModel from the environment
        self.assertEqual(req["inferenceConfig"], {"maxTokens": 600, "temperature": 0.2})
        self.assertIn("EUR", req["system"][0]["text"])
        self.assertEqual([t["toolSpec"]["name"] for t in req["toolConfig"]["tools"]],
                         ["list_products", "search_products", "get_product"])

    def test_session_id_never_sent_to_model(self):
        model = FakeModel(final("Hello."))
        make(model).ask("hi", "USD", "secret-session-abc")
        self.assertNotIn("secret-session-abc", repr(model.requests))

    def test_bad_currency_falls_back_to_usd(self):
        model = FakeModel(final("Hello."))
        make(model).ask("hi", "<script>")
        self.assertIn("currency is USD", model.requests[0]["system"][0]["text"])

    def test_get_product_unknown_id(self):
        model = FakeModel(tool_use("get_product", {"product_id": "NOPE"}), final("I don't know that product."))
        out = make(model).ask("Tell me about NOPE")
        result = model.requests[1]["messages"][2]["content"][0]["toolResult"]
        self.assertEqual(result["content"][0]["json"], {"product": None})
        self.assertEqual(out["products"], [])

    def test_empty_answer_is_refused(self):
        out = make(FakeModel(final("  "))).ask("hi")
        self.assertEqual(out["outcome"], "refused")


CANDLE = {"id": "0PUK6V6EV0", "name": "Candle Holder", "description": "The cheapest way to light up a room.",
          "price_usd": {"currency_code": "USD", "units": 18, "nanos": 990000000}, "categories": ["decor", "home"]}


class ThinkingTest(unittest.TestCase):
    """Amazon Nova may write its reasoning in <thinking> tags: shoppers never see it."""

    def test_strip_thinking(self):
        for raw, want in [
            # the first real answer in dev
            ("<thinking>I found only one product, the Candle Holder [0PUK6V6EV0], priced at 18.99 USD. "
             "It seems to be the cheapest product in the catalog.</thinking> The cheapest product in the "
             "catalog is the Candle Holder [0PUK6V6EV0], priced at 18.99 USD.",
             "The cheapest product in the catalog is the Candle Holder [0PUK6V6EV0], priced at 18.99 USD."),
            ("Answer one. <THINKING>a\nb</Thinking> Answer two.", "Answer one. Answer two."),
            ("The Mug is 8.99 USD. <thinking>cut off by maxTokens", "The Mug is 8.99 USD."),  # unclosed
            ("lost opening tag</thinking> The Mug is 8.99 USD.", "The Mug is 8.99 USD."),
            ("No reasoning here.", "No reasoning here."),
        ]:
            self.assertEqual(core.strip_thinking(raw), want)

    def test_answer_never_contains_thinking(self):
        model = FakeModel(final("<thinking>The user wants a mug [6E92ZMYYFZ].</thinking> Our Mug [6E92ZMYYFZ] costs 8.99 USD."))
        out = make(model).ask("mug?")
        self.assertEqual(out["outcome"], "answered")
        self.assertEqual(out["answer"], "Our Mug [6E92ZMYYFZ] costs 8.99 USD.")
        self.assertNotIn("thinking", out["answer"].lower())

    def test_only_thinking_is_refused(self):
        out = make(FakeModel(final("<thinking>no idea</thinking>"))).ask("hm?")
        self.assertEqual(out["outcome"], "refused")
        self.assertEqual(out["answer"], core.GIVE_UP_ANSWER)


class WholeCatalogTest(unittest.TestCase):
    """'Which product is the cheapest?': a keyword search misses products, list_products does not."""

    def test_cheapest_uses_the_full_list(self):
        catalog = FakeCatalog((MUG, JAR, CANDLE))
        # The trap of the first dev answer: searching "cheapest" finds only the Candle Holder.
        self.assertEqual([p["id"] for p in catalog.search("cheapest")], [CANDLE["id"]])
        catalog.searches.clear()

        model = FakeModel(tool_use("list_products", {}),
                          final("The cheapest product is the Bamboo Glass Jar [9SIQT8TOJO] at 5.49 USD."))
        metrics = FakeMetrics()
        out = make(model, catalog, metrics=metrics).ask("Which product is the cheapest?")

        listed = model.requests[1]["messages"][2]["content"][0]["toolResult"]["content"][0]["json"]["products"]
        self.assertEqual(sorted(p["id"] for p in listed), sorted([MUG["id"], JAR["id"], CANDLE["id"]]))
        jar = next(p for p in listed if p["id"] == JAR["id"])
        self.assertEqual(jar, {"id": "9SIQT8TOJO", "name": "Bamboo Glass Jar", "price_usd": "5.49 USD",
                               "categories": ["kitchen"]})  # no description, no picture
        self.assertEqual(catalog.searches, [])
        self.assertIn(("tool_call", {"tool": "list_products"}), metrics.counts)
        self.assertEqual(out["products"], [{"id": "9SIQT8TOJO", "name": "Bamboo Glass Jar"}])

    def test_prompt_sends_catalog_questions_to_list_products(self):
        model = FakeModel(final("ok"))
        make(model).ask("hi")
        system = model.requests[0]["system"][0]["text"]
        self.assertIn("call list_products", system)
        self.assertIn("cheapest", system)
        self.assertIn("<thinking>", system)  # told never to write it


class LimitsTest(unittest.TestCase):
    def test_tool_steps_are_capped(self):
        model = FakeModel(*[tool_use("search_products", {"query": "x"}, f"t{i}") for i in range(10)])
        out = make(model, max_tool_steps=3).ask("loop forever")
        self.assertEqual(out["outcome"], "too_many_steps")
        self.assertEqual(len(model.requests), 4)  # 3 tool rounds + the last call, then stop

    def test_deadline(self):
        now = [0.0]

        class SlowModel(FakeModel):
            def converse(self, request):
                now[0] += 10
                return super().converse(request)

        model = SlowModel(*[tool_use("search_products", {"query": "x"}, f"t{i}") for i in range(5)])
        out = make(model, deadline_seconds=15, clock=lambda: now[0]).ask("slow")
        self.assertEqual(out["outcome"], "timeout")
        self.assertEqual(len(model.requests), 2)

    def test_question_size(self):
        bot = make(FakeModel())
        with self.assertRaises(core.QuestionError):
            bot.ask("   ")
        with self.assertRaises(core.QuestionError):
            bot.ask("x" * 501)

    def test_rate_limit_per_session(self):
        now = [0.0]
        model = FakeModel(*[final("ok")] * 10)
        bot = make(model, rate_per_minute=10, rate_burst=2, clock=lambda: now[0])
        self.assertEqual(bot.ask("a", session="s1")["outcome"], "answered")
        self.assertEqual(bot.ask("b", session="s1")["outcome"], "answered")
        self.assertEqual(bot.ask("c", session="s1")["outcome"], "rate_limited")
        self.assertEqual(bot.ask("d", session="s2")["outcome"], "answered")  # another session
        now[0] += 6  # 10 a minute = one token every 6 s
        self.assertEqual(bot.ask("e", session="s1")["outcome"], "answered")
        self.assertEqual(len(model.requests), 4)

    def test_daily_cap_is_a_kill_switch(self):
        day = [datetime.date(2026, 10, 16)]
        model = FakeModel(*[final("ok")] * 5)
        bot = make(model, daily_question_cap=2, today=lambda: day[0])
        bot.ask("a", session="1")
        bot.ask("b", session="2")
        out = bot.ask("c", session="3")
        self.assertEqual(out["outcome"], "paused")
        self.assertEqual(out["answer"], core.PAUSED_ANSWER)
        self.assertEqual(len(model.requests), 2)  # no model call when paused
        day[0] = datetime.date(2026, 10, 17)
        self.assertEqual(bot.ask("d", session="4")["outcome"], "answered")

    def test_cap_zero_disables(self):
        model = FakeModel()
        self.assertEqual(make(model, daily_question_cap=0).ask("a")["outcome"], "paused")
        self.assertEqual(model.requests, [])


class PersonalDataTest(unittest.TestCase):
    def test_masking(self):
        text = core.mask_personal_data("I'm jane.doe+shop@example.co.uk, card 4111 1111 1111 1111, tel +33 6 12 34 56 78")
        self.assertNotIn("jane", text)
        self.assertNotIn("4111", text)
        self.assertNotIn("12 34 56", text)
        self.assertIn("[email]", text)
        self.assertIn("[number]", text)

    def test_short_numbers_kept(self):
        self.assertEqual(core.mask_personal_data("2 mugs under 10 dollars"), "2 mugs under 10 dollars")

    def test_model_gets_masked_question(self):
        model = FakeModel(final("ok"))
        make(model).ask("mail me at a@b.com")
        self.assertEqual(model.requests[0]["messages"][0]["content"][0]["text"], "mail me at [email]")


class ErrorsTest(unittest.TestCase):
    def test_model_error_is_a_clean_answer(self):
        metrics = FakeMetrics()
        out = make(FakeModel(bedrock.BedrockError("throttled", "slow down")), metrics=metrics).ask("hi")
        self.assertEqual(out["outcome"], "error")
        self.assertEqual(out["answer"], core.ERROR_ANSWER)
        self.assertIn(("bedrock_error", {"type": "throttled"}), metrics.counts)

    def test_semaphore_released_after_error(self):
        bot = make(FakeModel(RuntimeError("boom"), RuntimeError("boom"), RuntimeError("boom")), max_concurrent_calls=1)
        for _ in range(3):
            self.assertEqual(bot.ask("hi", session="x" + str(_))["outcome"], "error")

    def test_tool_error_goes_back_to_model(self):
        class BrokenCatalog(FakeCatalog):
            def search(self, query):
                raise RuntimeError("catalog down")

        model = FakeModel(tool_use("search_products", {"query": "mug"}), final("Sorry, I can't search now."))
        out = make(model, BrokenCatalog()).ask("mug?")
        result = model.requests[1]["messages"][2]["content"][0]["toolResult"]
        self.assertEqual(result["status"], "error")
        self.assertEqual(out["outcome"], "answered")

    def test_unknown_tool(self):
        model = FakeModel(tool_use("checkout", {"cart": "all"}), final("I can only search the catalog."))
        make(model).ask("buy everything")
        result = model.requests[1]["messages"][2]["content"][0]["toolResult"]
        self.assertEqual(result["status"], "error")
        self.assertIn("unknown tool", result["content"][0]["text"])


class BedrockTest(unittest.TestCase):
    def test_ping_is_one_token(self):
        model = FakeModel(final("p"))
        make(model).ping()
        self.assertEqual(model.requests[0]["inferenceConfig"], {"maxTokens": 1})
        self.assertNotIn("toolConfig", model.requests[0])

    def test_model_id(self):
        self.assertEqual(bedrock.model_id("amazon.nova-lite-v1:0", False), "amazon.nova-lite-v1:0")
        self.assertEqual(bedrock.model_id("amazon.nova-lite-v1:0", True), "us.amazon.nova-lite-v1:0")
        self.assertEqual(bedrock.model_id("us.amazon.nova-lite-v1:0", True), "us.amazon.nova-lite-v1:0")

    def test_model_adds_model_id(self):
        class StubClient:
            def __init__(self):
                self.kwargs = None

            def converse(self, **kwargs):
                self.kwargs = kwargs
                return final("ok")

        client = StubClient()
        bedrock.BedrockModel("amazon.nova-lite-v1:0", "us-east-1", client=client).converse({"messages": []})
        self.assertEqual(client.kwargs["modelId"], "amazon.nova-lite-v1:0")

    def test_error_classification(self):
        class ClientError(Exception):
            def __init__(self, code):
                super().__init__(code)
                self.response = {"Error": {"Code": code}}

        class ReadTimeoutError(Exception):
            pass

        class FailingClient:
            def __init__(self, err):
                self.err = err

            def converse(self, **kwargs):
                raise self.err

        for err, kind in [(ClientError("ThrottlingException"), "throttled"),
                          (ClientError("AccessDeniedException"), "access_denied"),
                          (ClientError("ValidationException"), "validation"),
                          (ReadTimeoutError("read timeout"), "timeout"),
                          (RuntimeError("?"), "other")]:
            with self.assertRaises(bedrock.BedrockError) as ctx:
                bedrock.BedrockModel("m", "us-east-1", client=FailingClient(err)).converse({})
            self.assertEqual(ctx.exception.kind, kind)


class FakeSpans:
    """Records what the tracing hook is given (tracing.OtelSpans has the same interface)."""

    def __init__(self):
        self.calls = []

    @contextlib.contextmanager
    def model_call(self, model_id, step):
        call = {"model_id": model_id, "step": step, "records": []}
        self.calls.append(call)

        class Recorder:
            def record(self, **fields):
                call["records"].append(fields)

        yield Recorder()


class SpanHookTest(unittest.TestCase):
    """One span per Bedrock call, built from typed fields only (ADR 0010)."""

    def test_one_call_per_step_with_tokens_tools_outcome(self):
        model = FakeModel(tool_use("search_products", {"query": "mug"}), final("The Mug [6E92ZMYYFZ]."))
        model.model_id = "amazon.nova-lite-v1:0"
        spans = FakeSpans()
        make(model, spans=spans).ask("SECRET-QUESTION mug?", "EUR", "SECRET-SESSION")
        self.assertEqual([(c["model_id"], c["step"]) for c in spans.calls],
                         [("amazon.nova-lite-v1:0", 0), ("amazon.nova-lite-v1:0", 1)])
        self.assertEqual(spans.calls[0]["records"],
                         [{"input_tokens": 100, "output_tokens": 10, "tools": ["search_products"], "outcome": "ok"}])
        self.assertEqual(spans.calls[1]["records"],
                         [{"input_tokens": 200, "output_tokens": 30, "tools": [], "outcome": "ok"}])
        # nothing the hook is given can carry the question, the answer or the session
        given = repr(spans.calls)
        for secret in ("SECRET-QUESTION", "SECRET-SESSION", core.session_key("SECRET-SESSION"), "Mug [6E92ZMYYFZ]"):
            self.assertNotIn(secret, given)

    def test_unknown_tool_name_is_not_passed_through(self):
        model = FakeModel(tool_use("drop_tables; --", {}), final("ok"))
        spans = FakeSpans()
        make(model, spans=spans).ask("hi")
        self.assertEqual(spans.calls[0]["records"][0]["tools"], ["unknown"])

    def test_error_outcomes(self):
        for kind, outcome in [("throttled", "rate_limited"), ("timeout", "timeout"), ("validation", "error")]:
            spans = FakeSpans()
            make(FakeModel(bedrock.BedrockError(kind, "x")), spans=spans).ask("hi")
            self.assertEqual(spans.calls[0]["records"], [{"outcome": outcome}], kind)

    def test_no_model_call_when_paused(self):
        spans = FakeSpans()
        out = make(FakeModel(), daily_question_cap=0, spans=spans).ask("hi")
        self.assertEqual(out["outcome"], "paused")
        self.assertEqual(spans.calls, [])


class CatalogCodeTest(unittest.TestCase):
    """The generated gRPC code loads with the pinned runtime (protobuf, grpcio): a mismatch fails
    here in CI instead of at the pod's start. No connection is made (gRPC channels are lazy)."""

    def test_generated_code_and_catalog_import(self):
        import grpc
        import demo_pb2
        import demo_pb2_grpc
        import catalog

        stub = demo_pb2_grpc.ProductCatalogServiceStub(grpc.insecure_channel("localhost:1"))
        for method in ("ListProducts", "GetProduct", "SearchProducts"):
            self.assertTrue(callable(getattr(stub, method)))

        product = demo_pb2.Product(id="6E92ZMYYFZ", name="Mug", categories=["kitchen"],
                                   price_usd=demo_pb2.Money(currency_code="USD", units=8, nanos=990000000))
        product = demo_pb2.Product.FromString(product.SerializeToString())  # round trip through the runtime
        self.assertEqual(catalog.to_dict(product)["price_usd"], {"currency_code": "USD", "units": 8, "nanos": 990000000})
        self.assertEqual(core.money(catalog.to_dict(product)["price_usd"]), "8.99 USD")
        self.assertEqual(demo_pb2.SearchProductsRequest(query="mug").query, "mug")


if __name__ == "__main__":
    unittest.main()
