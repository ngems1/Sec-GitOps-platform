using System;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry;
using OpenTelemetry.Exporter;
using OpenTelemetry.Instrumentation.StackExchangeRedis;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using StackExchange.Redis;

namespace cartservice
{
    // OpenTelemetry tracing (ADR 0010), started only with ENABLE_TRACING=1, like the other services:
    //   - service name and resource attributes from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES (set by
    //     the Helm chart); "cartservice" only when OTEL_SERVICE_NAME is not set;
    //   - ParentBased(AlwaysOn) sampler; W3C trace context + baggage (the .NET default propagator);
    //   - server spans for the gRPC calls (ASP.NET Core), health checks left out;
    //   - client spans for Redis (StackExchange.Redis): the command only, never the key (a cart's key is
    //     the shopper's session ID), so database statements stay non-verbose;
    //   - OTLP gRPC to COLLECTOR_SERVICE_ADDR in plain text, exported in the background (batch); a request
    //     never waits on the collector, and the exporter's own calls are not traced.
    public static class Tracing
    {
        public const string DefaultServiceName = "cartservice";
        private const string HealthCheckPath = "/grpc.health.v1.Health/Check";

        public static bool Enabled(IConfiguration configuration) =>
            configuration["ENABLE_TRACING"] == "1";

        // The resource: OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES (the SDK's environment detector),
        // and the default name only without OTEL_SERVICE_NAME (AddService would override it).
        public static void ConfigureResource(ResourceBuilder resource, Func<string, string> env)
        {
            if (string.IsNullOrEmpty(env("OTEL_SERVICE_NAME")))
            {
                resource.AddService(DefaultServiceName);
            }
        }

        public static void AddTracing(IServiceCollection services, IConfiguration configuration)
        {
            if (!Enabled(configuration))
            {
                Console.WriteLine("Tracing disabled.");
                return;
            }
            Console.WriteLine("Tracing enabled.");
            string collector = configuration["COLLECTOR_SERVICE_ADDR"];
            services.AddOpenTelemetry()
                .ConfigureResource(r => ConfigureResource(r, Environment.GetEnvironmentVariable))
                .WithTracing(tracing => tracing
                    .SetSampler(new ParentBasedSampler(new AlwaysOnSampler()))
                    .AddAspNetCoreInstrumentation(o =>
                    {
                        o.Filter = context => context.Request.Path != HealthCheckPath;
                    })
                    .AddRedisInstrumentation(o => o.SetVerboseDatabaseStatements = false)
                    .AddOtlpExporter(o =>
                    {
                        o.Protocol = OtlpExportProtocol.Grpc;
                        o.Endpoint = new Uri("http://" + collector);
                    }));
        }

        // Called by the Redis cache when it opens its connection (lazily, on the first cart call):
        // the connection is traced when tracing is on.
        public static void TraceRedisConnection(IServiceProvider provider, IConnectionMultiplexer connection)
        {
            provider.GetService<StackExchangeRedisInstrumentation>()?.AddConnection(connection);
        }
    }
}
