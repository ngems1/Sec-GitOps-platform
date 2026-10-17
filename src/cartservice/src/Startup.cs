using System;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using cartservice.cartstore;
using cartservice.services;
using Microsoft.Extensions.Caching.StackExchangeRedis;

namespace cartservice
{
    public class Startup
    {
        public Startup(IConfiguration configuration)
        {
            Configuration = configuration;
        }

        public IConfiguration Configuration { get; }
        
        // This method gets called by the runtime. Use this method to add services to the container.
        // For more information on how to configure your application, visit https://go.microsoft.com/fwlink/?LinkID=398940
        public void ConfigureServices(IServiceCollection services)
        {
            string redisAddress = Configuration["REDIS_ADDR"];
            string spannerProjectId = Configuration["SPANNER_PROJECT"];
            string spannerConnectionString = Configuration["SPANNER_CONNECTION_STRING"];
            string alloyDBConnectionString = Configuration["ALLOYDB_PRIMARY_IP"];

            if (!string.IsNullOrEmpty(redisAddress))
            {
                // ElastiCache: TLS (REDIS_TLS=true) and an auth token (REDIS_PASSWORD).
                // Both are unset for the local, in-cluster Redis.
                var redisOptions = StackExchange.Redis.ConfigurationOptions.Parse(redisAddress);
                redisOptions.Ssl = string.Equals(Configuration["REDIS_TLS"], "true", StringComparison.OrdinalIgnoreCase);
                string redisPassword = Configuration["REDIS_PASSWORD"];
                if (!string.IsNullOrEmpty(redisPassword))
                {
                    redisOptions.Password = redisPassword;
                }
                services.AddStackExchangeRedisCache(_ => { });
                // The cache still connects lazily (first cart call); the connection it opens is traced
                // when tracing is on (Tracing.cs).
                services.AddOptions<RedisCacheOptions>().Configure<IServiceProvider>((options, provider) =>
                {
                    options.ConfigurationOptions = redisOptions;
                    options.ConnectionMultiplexerFactory = async () =>
                    {
                        var connection = await StackExchange.Redis.ConnectionMultiplexer.ConnectAsync(redisOptions);
                        Tracing.TraceRedisConnection(provider, connection);
                        return connection;
                    };
                });
                services.AddSingleton<ICartStore, RedisCartStore>();
            }
            else if (!string.IsNullOrEmpty(spannerProjectId) || !string.IsNullOrEmpty(spannerConnectionString))
            {
                services.AddSingleton<ICartStore, SpannerCartStore>();
            }
            else if (!string.IsNullOrEmpty(alloyDBConnectionString))
            {
                Console.WriteLine("Creating AlloyDB cart store");
                services.AddSingleton<ICartStore, AlloyDBCartStore>();
            }
            else
            {
                Console.WriteLine("Redis cache host(hostname+port) was not specified. Starting a cart service using in memory store");
                services.AddDistributedMemoryCache();
                services.AddSingleton<ICartStore, RedisCartStore>();
            }


            services.AddGrpc();
            Tracing.AddTracing(services, Configuration);
        }

        // This method gets called by the runtime. Use this method to configure the HTTP request pipeline.
        public void Configure(IApplicationBuilder app, IWebHostEnvironment env)
        {
            if (env.IsDevelopment())
            {
                app.UseDeveloperExceptionPage();
            }

            app.UseRouting();

            app.UseEndpoints(endpoints =>
            {
                endpoints.MapGrpcService<CartService>();
                endpoints.MapGrpcService<cartservice.services.HealthCheckService>();

                endpoints.MapGet("/", async context =>
                {
                    await context.Response.WriteAsync("Communication with gRPC endpoints must be made through a gRPC client. To learn how to create a client, visit: https://go.microsoft.com/fwlink/?linkid=2086909");
                });
            });
        }
    }
}
