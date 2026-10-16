package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/sirupsen/logrus"
)

// withAssistant points ASSISTANT_URL at u for one test.
func withAssistant(t *testing.T, u string) {
	t.Helper()
	old := assistantURL
	assistantURL = u
	t.Cleanup(func() { assistantURL = old })
}

// fakeService answers POST /ask with a fixed status and body and records what it received
// (behind a mutex: the server runs in its own goroutine).
type fakeService struct {
	mu      sync.Mutex
	calls   int
	headers http.Header
	sent    map[string]string
}

func (f *fakeService) last() (int, http.Header, map[string]string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, f.headers, f.sent
}

func fakeAssistant(t *testing.T, status int, body string) (*httptest.Server, *fakeService) {
	t.Helper()
	f := &fakeService{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		sent := map[string]string{}
		_ = json.Unmarshal(b, &sent)
		f.mu.Lock()
		f.calls, f.headers, f.sent = f.calls+1, r.Header.Clone(), sent
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv, f
}

func withLog(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), ctxKeyLog{}, logrus.FieldLogger(logrus.New())))
}

// ask posts the form to the assistant page as a shopper with this session and currency.
func ask(question string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/assistant", strings.NewReader(url.Values{"question": {question}}.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.AddCookie(&http.Cookie{Name: cookieCurrency, Value: "EUR"})
	r = r.WithContext(context.WithValue(r.Context(), ctxKeySessionID{}, "session-123"))
	rec := httptest.NewRecorder()
	serveAssistant(rec, withLog(r), platformDetails{}, nil)
	return rec
}

func TestAssistantAnswerEscapedAndLinked(t *testing.T) {
	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered",
		"answer":"Try the Mug [6E92ZMYYFZ] <script>alert(1)</script>",
		"products":[{"id":"6E92ZMYYFZ","name":"Mug"},{"id":"../../cart","name":"bad"}]}`)
	withAssistant(t, srv.URL)

	rec := ask("Do you have a mug?")
	body := rec.Body.String()
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if strings.Contains(body, "<script>alert(1)</script>") || !strings.Contains(body, "&lt;script&gt;") {
		t.Error("the answer must be HTML-escaped")
	}
	if !strings.Contains(body, `Try the <a href="/product/6E92ZMYYFZ">Mug</a> &lt;script&gt;`) {
		t.Error("the citation is not a link named after the product")
	}
	if strings.Contains(body, "[6E92ZMYYFZ]") {
		t.Error("a raw product ID is shown")
	}
	if strings.Contains(body, "../../cart") {
		t.Error("a malformed product ID was linked")
	}
	_, headers, sent := f.last()
	if got := headers.Get("X-Session-Id"); got != hashedSession("session-123") || len(got) != 64 {
		t.Errorf("X-Session-Id = %q, want the SHA-256 of the session", got)
	}
	if sent["question"] != "Do you have a mug?" || sent["currency"] != "EUR" || len(sent) != 2 {
		t.Errorf("body sent = %v, want only question and currency", sent)
	}
}

func TestAssistantNeverSendsTheSessionID(t *testing.T) {
	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered","answer":"ok","products":[]}`)
	withAssistant(t, srv.URL)
	ask("hello")
	_, headers, sent := f.last()
	for k, v := range headers {
		if strings.Contains(strings.Join(v, ","), "session-123") {
			t.Errorf("header %s carries the raw session ID", k)
		}
	}
	for _, v := range sent {
		if strings.Contains(v, "session-123") {
			t.Error("the body carries the raw session ID")
		}
	}
}

func TestAssistantProblemsAreNever5xx(t *testing.T) {
	cases := map[string]struct {
		status int
		body   string
		want   int
	}{
		"paused":       {http.StatusOK, `{"outcome":"paused","answer":"The shopping assistant is paused for today.","products":[]}`, http.StatusOK},
		"bedrock down": {http.StatusBadGateway, `{"outcome":"error","answer":"Sorry, not available.","products":[]}`, http.StatusOK},
		"busy":         {http.StatusServiceUnavailable, `{"outcome":"busy","answer":"Busy.","products":[]}`, http.StatusOK},
		"html error":   {http.StatusInternalServerError, `<html>oops</html>`, http.StatusOK},
		"rate limited": {http.StatusTooManyRequests, `{"outcome":"rate_limited","answer":"Too fast.","products":[]}`, http.StatusTooManyRequests},
		"bad request":  {http.StatusBadRequest, `{"outcome":"bad_request","error":"too long"}`, http.StatusOK},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			srv, _ := fakeAssistant(t, c.status, c.body)
			withAssistant(t, srv.URL)
			rec := ask("hi")
			if rec.Code != c.want {
				t.Errorf("status %d, want %d", rec.Code, c.want)
			}
			if !strings.Contains(rec.Body.String(), "Shopping assistant") {
				t.Error("the page was not rendered")
			}
		})
	}
}

func TestAssistantUnreachable(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	u := srv.URL
	srv.Close() // nothing listens there any more
	withAssistant(t, u)
	rec := ask("hi")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), assistantUnavailable) {
		t.Errorf("status %d, or no unavailable message", rec.Code)
	}
}

func TestAssistantInputChecks(t *testing.T) {
	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered","answer":"ok","products":[]}`)
	withAssistant(t, srv.URL)
	for _, q := range []string{"   ", strings.Repeat("x", assistantMaxQuestion+1)} {
		if rec := ask(q); rec.Code != http.StatusOK {
			t.Errorf("status %d", rec.Code)
		}
	}
	if calls, _, _ := f.last(); calls != 0 {
		t.Error("an empty or too long question reached the service")
	}
}

func TestAssistantGetShowsForm(t *testing.T) {
	withAssistant(t, "http://assistant.invalid")
	rec := httptest.NewRecorder()
	serveAssistant(rec, withLog(httptest.NewRequest(http.MethodGet, "/assistant", nil)), platformDetails{}, nil)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `action="/assistant"`) {
		t.Errorf("status %d, or no form", rec.Code)
	}
}

func TestHeaderLinkOnlyWhenEnabled(t *testing.T) {
	render := func() string {
		var b strings.Builder
		if err := templates.ExecuteTemplate(&b, "header", map[string]interface{}{}); err != nil {
			t.Fatal(err)
		}
		return b.String()
	}
	withAssistant(t, "")
	if strings.Contains(render(), `href="/assistant"`) {
		t.Error("link shown while ASSISTANT_URL is empty")
	}
	withAssistant(t, "http://shoppingassistantservice")
	if !strings.Contains(render(), `href="/assistant"`) {
		t.Error("no link while ASSISTANT_URL is set")
	}
}

// A question waits seconds for the AI model: counted by status code, kept out of the p95.
func TestAssistantPostNotInLatency(t *testing.T) {
	m := newHTTPMetrics()
	h := m.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/assistant", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/assistant", nil))
	out := scrape(t, m)
	for _, want := range []string{
		`frontend_http_requests_total{code="200"} 2`,
		`frontend_http_request_duration_seconds_count 1`,
		`frontend_http_request_duration_seconds_bucket{le="+Inf"} 1`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrics output misses %q:\n%s", want, out)
		}
	}
}

func TestAnswerParts(t *testing.T) {
	products := []assistantProduct{{ID: "0PUK6V6EV0", Name: "Candle Holder"}, {ID: "9SIQT8TOJO", Name: "Bamboo Glass Jar"}}
	render := func(parts []answerPart) string {
		var b strings.Builder
		for _, p := range parts {
			if p.Link != "" {
				b.WriteString("<" + p.Link + "|" + p.Text + ">")
			} else {
				b.WriteString(p.Text)
			}
		}
		return b.String()
	}
	for answer, want := range map[string]string{
		// the name is just before the ID: it becomes the link
		"The cheapest is the candle holder [0PUK6V6EV0], at 18.99 USD.": "The cheapest is the </product/0PUK6V6EV0|candle holder>, at 18.99 USD.",
		// no name before the ID: the product's name is the link
		"Try this one: [9SIQT8TOJO].": "Try this one: </product/9SIQT8TOJO|Bamboo Glass Jar>.",
		"[9SIQT8TOJO] is cheap.":      "</product/9SIQT8TOJO|Bamboo Glass Jar> is cheap.",
		// an ID the service did not return is dropped, never shown or linked
		"See the Mug [6E92ZMYYFZ] and the Jar [9SIQT8TOJO].": "See the Mug and the Jar </product/9SIQT8TOJO|Bamboo Glass Jar>.",
		"No product here.": "No product here.",
	} {
		if got := render(answerParts(answer, products)); got != want {
			t.Errorf("answerParts(%q)\n got  %q\n want %q", answer, got, want)
		}
	}
}
