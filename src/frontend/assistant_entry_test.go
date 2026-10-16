package main

// Entry points to the shopping assistant: header link, floating "Ask AI" button, the
// product page's "Ask about this product" link and its prefilled question.

import (
	"html"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/frontend/genproto"
)

func renderTemplate(t *testing.T, name string, data map[string]interface{}) string {
	t.Helper()
	var b strings.Builder
	if err := templates.ExecuteTemplate(&b, name, data); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func productPage(t *testing.T, name string) string {
	t.Helper()
	product := struct {
		Item  *pb.Product
		Price *pb.Money
	}{&pb.Product{Id: "6E92ZMYYFZ", Name: name}, &pb.Money{CurrencyCode: "USD", Units: 8, Nanos: 990000000}}
	return renderTemplate(t, "product", map[string]interface{}{"product": product})
}

func TestIconAlwaysHasALabel(t *testing.T) {
	withAssistant(t, "http://shoppingassistantservice")
	header := renderTemplate(t, "header", map[string]interface{}{})
	if !strings.Contains(header, `<svg class="assistant-icon"`) || !strings.Contains(header, "<span>Shopping assistant</span>") {
		t.Errorf("header: no icon with the label \"Shopping assistant\":\n%s", header)
	}
	footer := renderTemplate(t, "footer", map[string]interface{}{})
	if !strings.Contains(footer, `class="assistant-fab"`) || !strings.Contains(footer, "<span>Ask AI</span>") {
		t.Errorf("floating button: no icon with the label \"Ask AI\":\n%s", footer)
	}
	if !strings.Contains(renderTemplate(t, "assistant_icon", nil), `aria-hidden="true"`) {
		t.Error("the icon must be decorative (aria-hidden): its label carries the meaning")
	}
}

func TestFloatingButton(t *testing.T) {
	withAssistant(t, "")
	if strings.Contains(renderTemplate(t, "footer", map[string]interface{}{}), "assistant-fab") {
		t.Error("floating button shown while ASSISTANT_URL is empty")
	}
	withAssistant(t, "http://shoppingassistantservice")
	if strings.Contains(renderTemplate(t, "footer", map[string]interface{}{"hide_assistant_fab": true}), "assistant-fab") {
		t.Error("floating button shown where it is hidden")
	}
	// not on the assistant page itself
	rec := httptest.NewRecorder()
	serveAssistant(rec, withLog(httptest.NewRequest(http.MethodGet, "/assistant", nil)), platformDetails{}, nil)
	if strings.Contains(rec.Body.String(), "assistant-fab") {
		t.Error("floating button shown on the assistant page")
	}
}

func TestProductPageAskLink(t *testing.T) {
	withAssistant(t, "")
	if strings.Contains(productPage(t, "Mug"), "Ask about this product") {
		t.Error("link shown while ASSISTANT_URL is empty")
	}
	withAssistant(t, "http://shoppingassistantservice")
	page := productPage(t, `Mug & <Co>`)
	if !strings.Contains(page, `href="/assistant?q=Tell%20me%20more%20about%20Mug%20%26%20`) {
		t.Errorf("no prefilled, query-escaped link:\n%s", page)
	}
	if !strings.Contains(page, "<span>Ask about this product</span>") {
		t.Error("no label on the link")
	}
	if strings.Contains(page, "<Co>") {
		t.Error("the product name is not escaped")
	}
}

func TestPrefillIsNeverSent(t *testing.T) {
	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered","answer":"ok","products":[]}`)
	withAssistant(t, srv.URL)
	r := httptest.NewRequest(http.MethodGet, "/assistant?q=Tell%20me%20more%20about%20%3Cb%3EMug%3C%2Fb%3E", nil)
	rec := httptest.NewRecorder()
	serveAssistant(rec, withLog(r), platformDetails{}, nil)
	body := rec.Body.String()
	if !strings.Contains(body, "Tell me more about &lt;b&gt;Mug&lt;/b&gt;</textarea>") {
		t.Errorf("the question is not prefilled (escaped) in the text box:\n%s", body)
	}
	if calls, _, _ := f.last(); calls != 0 {
		t.Error("a prefilled question was sent to the assistant without the shopper pressing Ask")
	}
}

func TestPrefillIsCapped(t *testing.T) {
	if got := prefill("  " + strings.Repeat("é", assistantMaxQuestion+10) + " "); len([]rune(got)) != assistantMaxQuestion {
		t.Errorf("prefill kept %d characters, want %d", len([]rune(got)), assistantMaxQuestion)
	}
	if prefill("  Tell me more about Mug ") != "Tell me more about Mug" {
		t.Error("prefill is not trimmed")
	}
}

func TestHeaderButton(t *testing.T) {
	withAssistant(t, "")
	if strings.Contains(renderTemplate(t, "header", map[string]interface{}{}), "assistant-link") {
		t.Error("header button shown while ASSISTANT_URL is empty")
	}
	withAssistant(t, "http://shoppingassistantservice")
	header := renderTemplate(t, "header", map[string]interface{}{})
	// the shop's primary button (red #CE0631, like Ask), icon + label
	want := `<a href="/assistant" class="cymbal-button-primary assistant-link"><svg class="assistant-icon"`
	if !strings.Contains(header, want) || !strings.Contains(header, "<span>Shopping assistant</span></a>") {
		t.Errorf("no primary header button with icon and label:\n%s", header)
	}
}

func TestFloatingButtonLeavesRoom(t *testing.T) {
	withAssistant(t, "")
	if strings.Contains(renderTemplate(t, "footer", map[string]interface{}{}), "assistant-fab-spacer") {
		t.Error("spacer rendered without the floating button")
	}
	withAssistant(t, "http://shoppingassistantservice")
	footer := renderTemplate(t, "footer", map[string]interface{}{})
	if !strings.Contains(footer, `<div class="assistant-fab-spacer" aria-hidden="true"></div>`) {
		t.Error("no room at the end of the page for the floating button")
	}
}

var chipHref = regexp.MustCompile(`class="assistant-chip" href="([^"]+)">([^<]+)</a>`)

func TestExampleChipsOnlyPrefill(t *testing.T) {
	withAssistant(t, "")
	if strings.Contains(renderTemplate(t, "assistant", map[string]interface{}{"examples": assistantExamples}), "assistant-chip") {
		t.Error("chips shown while ASSISTANT_URL is empty")
	}

	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered","answer":"ok","products":[]}`)
	withAssistant(t, srv.URL)
	rec := httptest.NewRecorder()
	serveAssistant(rec, withLog(httptest.NewRequest(http.MethodGet, "/assistant", nil)), platformDetails{}, nil)
	chips := chipHref.FindAllStringSubmatch(rec.Body.String(), -1)
	if len(chips) != len(assistantExamples) || len(chips) < 3 {
		t.Fatalf("%d chips rendered, want %d", len(chips), len(assistantExamples))
	}
	for i, c := range chips {
		href, label := html.UnescapeString(c[1]), html.UnescapeString(c[2])
		if label != assistantExamples[i] || !strings.HasPrefix(href, "/assistant?q=") {
			t.Errorf("chip %d: %q -> %q", i, label, href)
			continue
		}
		// Following the chip only fills the text box with the question.
		page := httptest.NewRecorder()
		serveAssistant(page, withLog(httptest.NewRequest(http.MethodGet, href, nil)), platformDetails{}, nil)
		if !strings.Contains(html.UnescapeString(page.Body.String()), ">"+label+"</textarea>") {
			t.Errorf("chip %q does not prefill the text box", label)
		}
	}
	if calls, _, _ := f.last(); calls != 0 {
		t.Error("a chip sent a question to the assistant")
	}
}
