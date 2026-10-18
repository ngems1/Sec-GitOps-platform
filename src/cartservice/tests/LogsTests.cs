using System;
using System.IO;
using System.Threading.Tasks;
using cartservice.cartstore;
using Microsoft.Extensions.Caching.Distributed;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using Xunit;

namespace cartservice.tests
{
    // The user ID is the shopper's session ID (the frontend's cookie): the cart store must never
    // write it to the logs (ADR 0011). Console is process-wide, so the test only checks that its
    // own unique user ID is absent, whatever other tests write meanwhile.
    [Collection("Console and tracing")]
    public class LogsTests
    {
        [Fact]
        public async Task CartStoreLogsNoUserId()
        {
            var store = new RedisCartStore(new MemoryDistributedCache(Options.Create(new MemoryDistributedCacheOptions())));
            string userId = "session-" + Guid.NewGuid().ToString("N");
            var output = new StringWriter();
            var original = Console.Out;
            Console.SetOut(output);
            try
            {
                await store.AddItemAsync(userId, "OLJCESPC7Z", 1);
                await store.GetCartAsync(userId);
                await store.EmptyCartAsync(userId);
            }
            finally
            {
                Console.SetOut(original);
            }
            string logs = output.ToString();
            Assert.Contains("AddItemAsync called", logs);
            Assert.DoesNotContain(userId, logs);
        }

        // A cache error's text can hold the key (the user ID): the gRPC error detail, which
        // Grpc.AspNetCore, checkout and the frontend log, carries the exception type only.
        [Fact]
        public async Task CartStoreErrorDetailHasNoUserId()
        {
            string userId = "session-" + Guid.NewGuid().ToString("N");
            var store = new RedisCartStore(new FailingCache());
            var error = await Assert.ThrowsAsync<Grpc.Core.RpcException>(() => store.GetCartAsync(userId));
            Assert.Equal("Can't access cart storage (TimeoutException)", error.Status.Detail);
            Assert.DoesNotContain(userId, error.Status.Detail);
            Assert.DoesNotContain(userId, error.Message);
        }

        private sealed class FailingCache : IDistributedCache
        {
            private static Exception Fail(string key) => new TimeoutException($"Timeout performing HGET (5000ms), key: {key}");
            public byte[] Get(string key) => throw Fail(key);
            public Task<byte[]> GetAsync(string key, System.Threading.CancellationToken token = default) => throw Fail(key);
            public void Refresh(string key) => throw Fail(key);
            public Task RefreshAsync(string key, System.Threading.CancellationToken token = default) => throw Fail(key);
            public void Remove(string key) => throw Fail(key);
            public Task RemoveAsync(string key, System.Threading.CancellationToken token = default) => throw Fail(key);
            public void Set(string key, byte[] value, DistributedCacheEntryOptions options) => throw Fail(key);
            public Task SetAsync(string key, byte[] value, DistributedCacheEntryOptions options, System.Threading.CancellationToken token = default) => throw Fail(key);
        }
    }
}
