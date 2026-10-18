package hipstershop;

import org.apache.logging.log4j.core.LogEvent;
import org.apache.logging.log4j.core.config.plugins.Plugin;
import org.apache.logging.log4j.core.config.plugins.PluginFactory;
import org.apache.logging.log4j.layout.template.json.resolver.EventResolver;
import org.apache.logging.log4j.layout.template.json.resolver.EventResolverContext;
import org.apache.logging.log4j.layout.template.json.resolver.EventResolverFactory;
import org.apache.logging.log4j.layout.template.json.resolver.TemplateResolver;
import org.apache.logging.log4j.layout.template.json.resolver.TemplateResolverConfig;
import org.apache.logging.log4j.layout.template.json.resolver.TemplateResolverFactory;
import org.apache.logging.log4j.layout.template.json.util.JsonWriter;

/**
 * The {@code "$resolver": "traceFlags"} of the JSON log template (boutique-log.json, ADR 0011):
 * {@code "01"} when the span is sampled, {@code "00"} when it is not, the same as every other
 * service. The OpenTelemetry Java agent puts the raw W3C flags byte in the Log4j context data
 * ({@code trace_flags}), which can be {@code "03"} (sampled + random trace ID): only the sampled
 * bit is kept. No field at all without the key: the agent is off (tracing off) or no span is
 * active.
 */
@Plugin(name = "TraceFlagsResolverFactory", category = TemplateResolverFactory.CATEGORY)
public final class TraceFlagsResolverFactory implements EventResolverFactory {

  private static final TraceFlagsResolverFactory INSTANCE = new TraceFlagsResolverFactory();

  private TraceFlagsResolverFactory() {}

  @PluginFactory
  public static TraceFlagsResolverFactory getInstance() {
    return INSTANCE;
  }

  @Override
  public String getName() {
    return "traceFlags";
  }

  @Override
  public TemplateResolver<LogEvent> create(
      EventResolverContext context, TemplateResolverConfig config) {
    return new EventResolver() {
      @Override
      public boolean isResolvable(LogEvent event) {
        return sampledFlag(event) != null;
      }

      @Override
      public void resolve(LogEvent event, JsonWriter writer) {
        writer.writeString(sampledFlag(event));
      }
    };
  }

  /** "01" or "00" from the agent's trace_flags, or null when there is none (or it is invalid). */
  static String sampledFlag(LogEvent event) {
    String flags = event.getContextData().getValue("trace_flags");
    if (flags == null || flags.length() != 2) {
      return null;
    }
    try {
      return (Integer.parseInt(flags, 16) & 0x01) == 0x01 ? "01" : "00";
    } catch (NumberFormatException e) {
      return null;
    }
  }
}
