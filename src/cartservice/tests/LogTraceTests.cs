using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Grpc.Core;
using Grpc.Net.Client;
using Hipstershop;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Xunit;
using static Hipstershop.CartService;

namespace cartservice.tests
{
    // Console and ActivitySource listeners are process-wide: these tests, TracingTests and LogsTests
    // run one at a time.
    [CollectionDefinition("Console and tracing", DisableParallelization = true)]
    public class ConsoleAndTracingCollection { }

    // trace_id / span_id / trace_flags in the cart's JSON log lines (CartLog.cs, ADR 0011).
    [Collection("Console and tracing")]
    public class LogTraceTests
    {
        private const string CallerTraceId = "4bf92f3577b34da6a3ce929d0e0e4736";
        private const string CallerSpanId = "00f067aa0ba902b7";

        private static async Task<Dictionary<string, string>> GetCartLine(bool tracing, string callerFlags)
        {
            var config = new Dictionary<string, string>();
            if (tracing)
            {
                config["ENABLE_TRACING"] = "1";
                config["COLLECTOR_SERVICE_ADDR"] = "127.0.0.1:1"; // nothing listens there
            }
            using var host = await new HostBuilder()
                .ConfigureAppConfiguration(c => c.AddInMemoryCollection(config))
                .ConfigureWebHost(web => web.UseStartup<Startup>().UseTestServer())
                .StartAsync();
            var http = host.GetTestClient();
            var client = new CartServiceClient(GrpcChannel.ForAddress(http.BaseAddress, new GrpcChannelOptions { HttpClient = http }));

            var output = new StringWriter();
            var original = Console.Out;
            Console.SetOut(output);
            try
            {
                var headers = new Metadata { { "traceparent", $"00-{CallerTraceId}-{CallerSpanId}-{callerFlags}" } };
                await client.GetCartAsync(new GetCartRequest { UserId = Guid.NewGuid().ToString() }, headers);
            }
            finally
            {
                Console.SetOut(original);
            }
            var line = output.ToString().Split('\n').Select(l => l.Trim())
                .Single(l => l.StartsWith("{") && l.Contains("GetCartAsync called"));
            return JsonSerializer.Deserialize<Dictionary<string, string>>(line);
        }

        [Fact]
        public async Task Tracing_on_the_request_span_IDs()
        {
            var line = await GetCartLine(tracing: true, callerFlags: "01");
            Assert.Equal(CallerTraceId, line["trace_id"]);           // the caller's trace, continued
            Assert.Matches("^[0-9a-f]{16}$", line["span_id"]);
            Assert.NotEqual(CallerSpanId, line["span_id"]);          // our server span, not the caller's
            Assert.Equal("01", line["trace_flags"]);
            Assert.Equal("INFO", line["severity"]);                  // the line's own fields
            Assert.Equal("GetCartAsync called", line["message"]);
            Assert.True(line.ContainsKey("timestamp"));
        }

        [Fact]
        public async Task Tracing_on_unsampled_caller_gives_00()
        {
            var line = await GetCartLine(tracing: true, callerFlags: "00");
            Assert.Equal(CallerTraceId, line["trace_id"]);
            Assert.Equal("00", line["trace_flags"]);
        }

        [Fact]
        public async Task Tracing_off_no_fields_even_with_a_caller_traceparent()
        {
            var line = await GetCartLine(tracing: false, callerFlags: "01");
            Assert.Equal("GetCartAsync called", line["message"]);
            foreach (var key in new[] { "trace_id", "span_id", "trace_flags" })
            {
                Assert.False(line.ContainsKey(key), $"{key} should be absent: {string.Join(",", line)}");
            }
        }

        // An Activity made from a caller's traceparent without OpenTelemetry listening (what ASP.NET
        // Core does when something else subscribes to its diagnostics): its IDs must not be logged.
        [Fact]
        public void Caller_activity_without_OpenTelemetry_no_fields()
        {
            using var activity = new System.Diagnostics.Activity("caller")
                .SetParentId($"00-{CallerTraceId}-{CallerSpanId}-01").Start();
            Assert.Equal(CallerTraceId, activity.TraceId.ToHexString()); // the case covered
            var line = JsonSerializer.Deserialize<Dictionary<string, string>>(CartLog.Line("INFO", "caller activity"));
            Assert.False(line.ContainsKey("trace_id"), string.Join(",", line));
        }

        [Fact]
        public void Outside_a_span_no_fields()
        {
            var line = JsonSerializer.Deserialize<Dictionary<string, string>>(CartLog.Line("INFO", "no request"));
            Assert.Equal(new[] { "message", "severity", "timestamp" }, line.Keys.OrderBy(k => k));
        }
    }
}
