package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// AlertType classifies the kind of alert being sent.
type AlertType int

const (
	NewRelease   AlertType = iota
	CVEFound
	ServiceDown
	HighResource
)

func (a AlertType) String() string {
	switch a {
	case NewRelease:
		return "NewRelease"
	case CVEFound:
		return "CVEFound"
	case ServiceDown:
		return "ServiceDown"
	case HighResource:
		return "HighResource"
	default:
		return "Unknown"
	}
}

// Alert represents a single alert to be sent.
type Alert struct {
	Type    AlertType
	Service string
	Message string
}

// Alerter sends notifications via Telegram Bot API with rate limiting and cooldowns.
type Alerter struct {
	botToken string
	chatID   string
	client   *http.Client

	mu            sync.Mutex
	lastSendTime  time.Time
	cooldowns     map[string]time.Time // key: "alertType:service" -> last alert time
	minInterval   time.Duration        // minimum time between any two messages (Telegram limit)
	cooldownByType map[AlertType]time.Duration
}

// NewAlerter creates a new Alerter with Telegram configuration.
func NewAlerter(cfg TelegramConfig) *Alerter {
	return &Alerter{
		botToken: cfg.BotToken,
		chatID:   cfg.ChatID,
		client:   &http.Client{Timeout: 10 * time.Second},
		cooldowns: make(map[string]time.Time),
		minInterval: 5 * time.Second,
		cooldownByType: map[AlertType]time.Duration{
			NewRelease:   1 * time.Hour,
			CVEFound:     6 * time.Hour,
			ServiceDown:  15 * time.Minute,
			HighResource: 30 * time.Minute,
		},
	}
}

// Send dispatches an alert via Telegram, respecting rate limits and cooldowns.
func (a *Alerter) Send(ctx context.Context, alert Alert) {
	if a.botToken == "" || a.chatID == "" {
		logJSON("warn", "telegram not configured, skipping alert", map[string]string{
			"type":    alert.Type.String(),
			"service": alert.Service,
		})
		return
	}

	a.mu.Lock()

	// Check per-type cooldown
	cooldownKey := fmt.Sprintf("%s:%s", alert.Type.String(), alert.Service)
	if lastTime, ok := a.cooldowns[cooldownKey]; ok {
		cooldownDuration := a.cooldownByType[alert.Type]
		if time.Since(lastTime) < cooldownDuration {
			a.mu.Unlock()
			logJSON("debug", "alert suppressed by cooldown", map[string]string{
				"type":    alert.Type.String(),
				"service": alert.Service,
			})
			return
		}
	}

	// Enforce minimum interval between messages (Telegram rate limit)
	if !a.lastSendTime.IsZero() {
		elapsed := time.Since(a.lastSendTime)
		if elapsed < a.minInterval {
			wait := a.minInterval - elapsed
			a.mu.Unlock()
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return
			}
			a.mu.Lock()
		}
	}

	a.lastSendTime = time.Now()
	a.cooldowns[cooldownKey] = time.Now()
	a.mu.Unlock()

	a.sendTelegram(ctx, alert.Message)
}

func (a *Alerter) sendTelegram(ctx context.Context, text string) {
	apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", a.botToken)

	params := url.Values{}
	params.Set("chat_id", a.chatID)
	params.Set("text", text)
	params.Set("parse_mode", "Markdown")
	params.Set("disable_web_page_preview", "true")

	req, err := http.NewRequestWithContext(ctx, "POST", apiURL, nil)
	if err != nil {
		logJSON("error", "failed to create telegram request", map[string]string{"error": err.Error()})
		return
	}
	req.URL.RawQuery = params.Encode()

	resp, err := a.client.Do(req)
	if err != nil {
		logJSON("error", "failed to send telegram message", map[string]string{"error": err.Error()})
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusOK {
		logJSON("error", "telegram API error", map[string]string{
			"status": fmt.Sprintf("%d", resp.StatusCode),
		})
		return
	}

	logJSON("info", "telegram alert sent", map[string]string{
		"text_length": fmt.Sprintf("%d", len(text)),
	})
}
