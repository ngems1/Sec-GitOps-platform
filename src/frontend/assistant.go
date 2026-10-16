package main

// The AI shopping assistant page (ADR 0009): GET /assistant shows a question form, POST
// /assistant sends the question to shoppingassistantservice and shows its answer.
//
// Behind a flag: with ASSISTANT_URL empty the routes are not registered (404) and the header
// has no link. The page never answers a 5xx because of the assistant (off, paused, slow,
// down): those are shown as a message with a 200, so they cannot fail the frontend canary.
// It calls no other service either (no cart, no currency list), so it stays fast.
//
// What leaves the frontend: the question, the shopper's currency and a SHA-256 of the
// session ID (X-Session-Id, the per-shopper rate-limit key). Never the session ID itself.
// The answer is rendered by html/template (escaped). The service cites products as "Name [ID]":
// each citation becomes a link named after the product, only for the product IDs the service
// returned (it validated them against the catalog); any other [ID] is removed. No raw ID shows.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/sirupsen/logrus"
)

const (
	assistantTimeout      = 30 * time.Second
	assistantMaxQuestion  = 500     // same cap as the service (MAX_QUESTION_CHARS)
	assistantMaxReplySize = 1 << 16 // bytes read from the service
	assistantUnavailable  = "The shopping assistant is not available right now. Please try again in a moment."
)

var (
	assistantURL    = strings.TrimRight(strings.TrimSpace(os.Getenv("ASSISTANT_URL")), "/")
	assistantClient = &http.Client{Timeout: assistantTimeout}
	productIDFormat = regexp.MustCompile(`^[A-Z0-9]{6,20}$`)
	citedIDPattern  = regexp.MustCompile(`\s*\[([A-Z0-9]{6,20})\]`)
)

func assistantEnabled() bool { return assistantURL != "" }

type assistantProduct struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type assistantReply struct {
	Outcome  string             `json:"outcome"`
	Answer   string             `json:"answer"`
	Error    string             `json:"error"`
	Products []assistantProduct `json:"products"`
}

// hashedSession is the rate-limit key sent to the service: the session ID never leaves.
func hashedSession(sessionID string) string {
	sum := sha256.Sum256([]byte(sessionID))
	return hex.EncodeToString(sum[:])
}

// askAssistant calls POST {ASSISTANT_URL}/ask. Every failure becomes a reply with a message
// for the shopper, so the caller never has to turn it into an error page.
func askAssistant(question, currency, sessionID string) (assistantReply, int) {
	body, _ := json.Marshal(map[string]string{"question": question, "currency": currency})
	req, err := http.NewRequest(http.MethodPost, assistantURL+"/ask", bytes.NewReader(body))
	if err != nil {
		return assistantReply{Outcome: "error", Answer: assistantUnavailable, Error: err.Error()}, 0
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Session-Id", hashedSession(sessionID))
	resp, err := assistantClient.Do(req)
	if err != nil {
		return assistantReply{Outcome: "unreachable", Answer: assistantUnavailable, Error: err.Error()}, 0
	}
	defer resp.Body.Close()
	var reply assistantReply
	if err := json.NewDecoder(io.LimitReader(resp.Body, assistantMaxReplySize)).Decode(&reply); err != nil || (reply.Answer == "" && reply.Error == "") {
		return assistantReply{Outcome: "error", Answer: assistantUnavailable, Error: fmt.Sprintf("status %d, unreadable reply", resp.StatusCode)}, resp.StatusCode
	}
	if reply.Answer == "" { // 400 from the service: {"outcome": "bad_request", "error": "..."}
		reply.Answer = "Sorry, I can't answer that question. Please rephrase it."
	}
	// Defence in depth: link only well-formed IDs (the service already checked the catalog).
	products := reply.Products[:0]
	for _, p := range reply.Products {
		if productIDFormat.MatchString(p.ID) {
			products = append(products, p)
		}
	}
	reply.Products = products
	return reply, resp.StatusCode
}

func (fe *frontendServer) assistantHandler(w http.ResponseWriter, r *http.Request) {
	serveAssistant(w, r, plat, deploymentDetailsMap)
}

// serveAssistant takes the platform and the footer details as arguments (globals written by
// other goroutines), so the tests can call it under the race detector.
func serveAssistant(w http.ResponseWriter, r *http.Request, p platformDetails, details map[string]string) {
	log := r.Context().Value(ctxKeyLog{}).(logrus.FieldLogger)
	data := map[string]interface{}{
		"session_id":        sessionID(r),
		"request_id":        r.Context().Value(ctxKeyRequestID{}),
		"user_currency":     currentCurrency(r),
		"show_currency":     false,
		"platform_css":      p.css,
		"platform_name":     p.provider,
		"is_cymbal_brand":   isCymbalBrand,
		"deploymentDetails": details,
		"frontendMessage":   frontendMessage,
		"max_question":      assistantMaxQuestion,
	}
	status := http.StatusOK
	if r.Method == http.MethodPost {
		question := strings.TrimSpace(r.FormValue("question"))
		data["question"] = question
		switch {
		case question == "":
			data["answer"] = "Please type a question about our products."
		case len([]rune(question)) > assistantMaxQuestion:
			data["answer"] = fmt.Sprintf("Please keep your question under %d characters.", assistantMaxQuestion)
		default:
			start := time.Now()
			reply, code := askAssistant(question, currentCurrency(r), sessionID(r))
			fields := logrus.Fields{"outcome": reply.Outcome, "assistant.status": code,
				"took_ms": time.Since(start).Milliseconds(), "products": len(reply.Products)}
			if reply.Error != "" {
				fields["error"] = reply.Error
			}
			log.WithFields(fields).Info("assistant question") // never the question text
			data["answer"] = reply.Answer
			data["products"] = reply.Products
			if code == http.StatusTooManyRequests {
				status = http.StatusTooManyRequests // a 4xx: not counted as an error by the canary
			}
		}
	}
	if answer, ok := data["answer"].(string); ok {
		products, _ := data["products"].([]assistantProduct)
		data["answer_parts"] = answerParts(answer, products)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := templates.ExecuteTemplate(w, "assistant", data); err != nil {
		log.Println(err)
	}
}

// answerPart is a piece of the answer: plain text, or a product link when Link is set.
type answerPart struct {
	Text string
	Link string
}

// answerParts turns each "Name [ID]" citation into a link labelled with the name (or, when
// the name is not just before it, with the product's name), for the products the service
// returned only. Any other [ID] is dropped, so the shopper never sees a raw product ID.
// The template escapes every part.
func answerParts(answer string, products []assistantProduct) []answerPart {
	byID := make(map[string]assistantProduct, len(products))
	for _, p := range products {
		byID[p.ID] = p
	}
	var parts []answerPart
	last := 0
	for _, m := range citedIDPattern.FindAllStringSubmatchIndex(answer, -1) {
		before := answer[last:m[0]]
		last = m[1]
		p, ok := byID[answer[m[2]:m[3]]]
		if !ok || p.Name == "" {
			parts = append(parts, answerPart{Text: before})
			continue
		}
		label := p.Name
		if n := len(p.Name); len(before) >= n && strings.EqualFold(before[len(before)-n:], p.Name) {
			label, before = before[len(before)-n:], before[:len(before)-n] // "the Mug [ID]" -> "the " + link "Mug"
		} else if before != "" {
			before += " " // "is [ID]" -> "is " + link "Mug"
		}
		parts = append(parts, answerPart{Text: before}, answerPart{Text: label, Link: "/product/" + p.ID})
	}
	parts = append(parts, answerPart{Text: answer[last:]})
	return parts
}
