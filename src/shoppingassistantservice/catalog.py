"""Read-only access to productcatalogservice over gRPC (ListProducts, GetProduct, SearchProducts).

The assistant never writes anything: no cart, no checkout, no order. Products are returned
as plain dicts so assistant.py does not depend on protobuf.
"""
import threading
import time

import grpc

import demo_pb2
import demo_pb2_grpc

CACHE_SECONDS = 300


def to_dict(p):
    return {
        "id": p.id,
        "name": p.name,
        "description": p.description,
        "price_usd": {"currency_code": p.price_usd.currency_code, "units": p.price_usd.units,
                      "nanos": p.price_usd.nanos},
        "categories": list(p.categories),
    }


class Catalog:
    """One gRPC channel to the catalog for the whole process, made once and shared by every
    question's tool calls (a channel multiplexes concurrent calls over one HTTP/2 connection and
    reconnects by itself). Closed by close() at shutdown."""

    def __init__(self, addr, timeout_seconds=3):
        self.channel = grpc.insecure_channel(addr)
        self.stub = demo_pb2_grpc.ProductCatalogServiceStub(self.channel)
        self.timeout = timeout_seconds
        self.lock = threading.Lock()
        self.products = {}
        self.loaded_at = 0.0

    def _all(self):
        """Every product by ID, cached for CACHE_SECONDS (the catalog is small and static)."""
        with self.lock:
            if not self.products or time.monotonic() - self.loaded_at > CACHE_SECONDS:
                resp = self.stub.ListProducts(demo_pb2.Empty(), timeout=self.timeout)
                self.products = {p.id: to_dict(p) for p in resp.products}
                self.loaded_at = time.monotonic()
            return self.products

    def list_products(self):
        """The whole catalog (small: the list_products tool sends it to the model)."""
        return list(self._all().values())

    def search(self, query):
        resp = self.stub.SearchProducts(demo_pb2.SearchProductsRequest(query=query), timeout=self.timeout)
        return [to_dict(p) for p in resp.results]

    def get(self, product_id):
        return self._all().get(product_id)

    def product_ids(self):
        return set(self._all())

    def close(self):
        self.channel.close()
