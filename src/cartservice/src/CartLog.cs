using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.Json;

namespace cartservice
{
    // The cart's request log lines (ADR 0011, step 6): one JSON object per line,
    //   {"timestamp": "...", "severity": "INFO", "message": "GetCartAsync called",
    //    "trace_id": "4bf92f35...", "span_id": "00f067aa...", "trace_flags": "01"}
    // trace_id / span_id / trace_flags (lower-case hex as in a W3C traceparent; "01" sampled, "00"
    // not) are the names of ADR 0011, the same in every service. They come from the current
    // Activity only while OpenTelemetry listens to its source (tracing on, Tracing.cs): ASP.NET
    // Core also creates an Activity from a caller's traceparent with tracing off, and that caller's
    // IDs must never reach our logs. Never the user ID (the shopper's session ID) or cart contents.
    public static class CartLog
    {
        public static void Info(string message) => Console.WriteLine(Line("INFO", message));

        public static string Line(string severity, string message)
        {
            var fields = new Dictionary<string, string>
            {
                ["timestamp"] = DateTime.UtcNow.ToString("o"),
                ["severity"] = severity,
                ["message"] = message,
            };
            foreach (var field in TraceFields(Activity.Current))
            {
                fields[field.Key] = field.Value;
            }
            return JsonSerializer.Serialize(fields);
        }

        public static IEnumerable<KeyValuePair<string, string>> TraceFields(Activity activity)
        {
            if (activity == null || activity.IdFormat != ActivityIdFormat.W3C || activity.TraceId == default
                || !activity.Source.HasListeners())
            {
                yield break;
            }
            yield return new KeyValuePair<string, string>("trace_id", activity.TraceId.ToHexString());
            yield return new KeyValuePair<string, string>("span_id", activity.SpanId.ToHexString());
            yield return new KeyValuePair<string, string>("trace_flags",
                activity.ActivityTraceFlags.HasFlag(ActivityTraceFlags.Recorded) ? "01" : "00");
        }
    }
}
