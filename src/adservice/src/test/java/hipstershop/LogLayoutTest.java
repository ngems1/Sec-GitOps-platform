package hipstershop;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.HashMap;
import java.util.Map;
import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.core.LogEvent;
import org.apache.logging.log4j.core.LoggerContext;
import org.apache.logging.log4j.core.config.DefaultConfiguration;
import org.apache.logging.log4j.core.impl.Log4jLogEvent;
import org.apache.logging.log4j.layout.template.json.JsonTemplateLayout;
import org.apache.logging.log4j.message.SimpleMessage;
import org.apache.logging.log4j.util.SortedArrayStringMap;
import org.junit.Test;

/**
 * The JSON log line of adservice (log4j2.xml, boutique-log.json, ADR 0011): the keys the
 * OpenTelemetry Java agent puts in the Log4j context data become trace_id, span_id and
 * trace_flags ("01"/"00"); without them (agent off: tracing off, or no active span) the fields are
 * absent. The agent itself was checked end to end (agent 2.32.0, on and off) when this was added.
 */
public class LogLayoutTest {

  private static final String TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736";
  private static final String SPAN_ID = "00f067aa0ba902b7";

  private static String line(Map<String, String> contextData) {
    JsonTemplateLayout layout =
        JsonTemplateLayout.newBuilder()
            .setConfiguration(new DefaultConfiguration())
            .setEventTemplateUri("classpath:boutique-log.json")
            .build();
    SortedArrayStringMap data = new SortedArrayStringMap();
    contextData.forEach(data::putValue);
    LogEvent event =
        Log4jLogEvent.newBuilder()
            .setLoggerName("hipstershop.AdService")
            .setLevel(Level.INFO)
            .setMessage(new SimpleMessage("received ad request (context_words=[kitchen])"))
            .setContextData(data)
            .build();
    return layout.toSerializable(event);
  }

  private static Map<String, String> agentData(String flags) {
    Map<String, String> m = new HashMap<>();
    m.put("trace_id", TRACE_ID);
    m.put("span_id", SPAN_ID);
    m.put("trace_flags", flags);
    return m;
  }

  @Test
  public void spanFieldsFromTheAgentContextData() {
    String json = line(agentData("01"));
    assertTrue(json, json.contains("\"trace_id\":\"" + TRACE_ID + "\""));
    assertTrue(json, json.contains("\"span_id\":\"" + SPAN_ID + "\""));
    assertTrue(json, json.contains("\"trace_flags\":\"01\""));
  }

  @Test
  public void onlyTheSampledBitIsKept() {
    // agent 2.32.0 writes "03" for a sampled span (W3C random trace ID flag too)
    assertTrue(line(agentData("03")).contains("\"trace_flags\":\"01\""));
    assertTrue(line(agentData("00")).contains("\"trace_flags\":\"00\""));
    assertTrue(line(agentData("02")).contains("\"trace_flags\":\"00\""));
    assertFalse(line(agentData("zz")).contains("\"trace_flags\""));
  }

  @Test
  public void noFieldsWithoutTheAgentContextData() {
    String json = line(new HashMap<>());
    for (String key : new String[] {"trace_id", "span_id", "trace_flags"}) {
      assertFalse(key + " should be absent: " + json, json.contains("\"" + key + "\""));
    }
  }

  @Test
  public void theExistingFieldsStayAndTheStackdriverKeysAreGone() {
    String json = line(agentData("01"));
    for (String key :
        new String[] {
          "instant", "thread", "level", "loggerName", "message", "endOfBatch", "loggerFqcn",
          "threadId", "threadPriority", "time"
        }) {
      assertTrue(key + " missing: " + json, json.contains("\"" + key + "\":"));
    }
    assertTrue(json, json.contains("\"message\":\"received ad request (context_words=[kitchen])\""));
    assertFalse(json, json.contains("logging.googleapis.com"));
    assertFalse(json, json.contains("${ctx:"));
  }

  @Test
  public void log4j2XmlUsesThisLayout() {
    LoggerContext context = (LoggerContext) LogManager.getContext(false);
    assertEquals(
        JsonTemplateLayout.class,
        context.getConfiguration().getAppender("STDOUT").getLayout().getClass());
  }
}
