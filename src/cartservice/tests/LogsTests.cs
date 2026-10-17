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
    }
}
