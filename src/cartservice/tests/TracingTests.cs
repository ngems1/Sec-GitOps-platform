using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Grpc.Net.Client;
using Hipstershop;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Xunit;
using static Hipstershop.CartService;

namespace cartservice.tests
{
    // Tracing (ADR 0010, src/Tracing.cs): off unless ENABLE_TRACING=1, service name from env, and an
    // unreachable collector never blocks a request.
    public class TracingTests
    {
        private static IHostBuilder Host(Dictionary<string, string> config, List<Activity> exported = null) =>
            new HostBuilder()
                .ConfigureAppConfiguration(c => c.AddInMemoryCollection(config))
                .ConfigureWebHost(web => web.UseStartup<Startup>().UseTestServer()
                    // The spans the SDK would export, after its filters (in addition to the OTLP exporter).
                    .ConfigureServices(s => { if (exported != null) s.ConfigureOpenTelemetryTracerProvider(b => b.AddInMemoryExporter(exported)); }));

        private static CartServiceClient Client(IHost host)
        {
            var http = host.GetTestClient();
            return new CartServiceClient(GrpcChannel.ForAddress(http.BaseAddress, new GrpcChannelOptions { HttpClient = http }));
        }

        [Fact]
        public async Task Off_without_ENABLE_TRACING()
        {
            using var host = await Host(new Dictionary<string, string>()).StartAsync();
            Assert.Null(host.Services.GetService<TracerProvider>());
        }

        [Fact]
        public void Default_service_name_only_without_OTEL_SERVICE_NAME()
        {
            var withoutEnv = ResourceBuilder.CreateEmpty();
            Tracing.ConfigureResource(withoutEnv, _ => null);
            Assert.Contains(withoutEnv.Build().Attributes,
                a => a.Key == "service.name" && (string)a.Value == "cartservice");

            var withEnv = ResourceBuilder.CreateEmpty();
            Tracing.ConfigureResource(withEnv, k => k == "OTEL_SERVICE_NAME" ? "cartservice-from-env" : null);
            Assert.DoesNotContain(withEnv.Build().Attributes, a => a.Key == "service.name");
        }

        [Fact]
        public async Task Collector_unreachable_requests_still_answer_quickly()
        {
            var spans = new List<Activity>();
            using var host = await Host(new Dictionary<string, string>
            {
                ["ENABLE_TRACING"] = "1",
                ["COLLECTOR_SERVICE_ADDR"] = "127.0.0.1:1", // nothing listens there
            }, spans).StartAsync();
            Assert.NotNull(host.Services.GetService<TracerProvider>());

            var client = Client(host);
            var watch = Stopwatch.StartNew();
            for (var i = 0; i < 20; i++)
            {
                var cart = await client.GetCartAsync(new GetCartRequest { UserId = Guid.NewGuid().ToString() });
                Assert.NotNull(cart);
            }
            Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5), $"20 calls took {watch.Elapsed}");

            // Health checks make no span; cart calls do.
            await new Grpc.Health.V1.Health.HealthClient(GrpcChannel.ForAddress(host.GetTestClient().BaseAddress,
                new GrpcChannelOptions { HttpClient = host.GetTestClient() })).CheckAsync(new Grpc.Health.V1.HealthCheckRequest());
            host.Services.GetRequiredService<TracerProvider>().ForceFlush();
            Assert.Contains(spans, a => a.DisplayName.Contains("GetCart"));
            Assert.DoesNotContain(spans, a => a.DisplayName.Contains("grpc.health.v1.Health"));
        }
    }
}
