package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func main() {
	configPath := flag.String("config", "config.toml", "path to config file")
	flag.Parse()

	logJSON("info", "starting carcinologistd", map[string]string{
		"config": *configPath,
		"pid":    fmt.Sprintf("%d", os.Getpid()),
	})

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		logJSON("fatal", "failed to load config", map[string]string{"error": err.Error()})
		os.Exit(1)
	}

	// Override telegram config from environment if set
	if tok := os.Getenv("CARCINOLOGISTD_TELEGRAM_TOKEN"); tok != "" {
		cfg.Telegram.BotToken = tok
	}
	if chat := os.Getenv("CARCINOLOGISTD_TELEGRAM_CHAT"); chat != "" {
		cfg.Telegram.ChatID = chat
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	alerter := NewAlerter(cfg.Telegram)

	state, err := LoadState()
	if err != nil {
		logJSON("warn", "failed to load state, starting fresh", map[string]string{"error": err.Error()})
		state = NewState()
	}

	repoInterval, err := time.ParseDuration(cfg.Intervals.RepoCheck)
	if err != nil {
		logJSON("fatal", "invalid repo_check interval", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
	healthInterval, err := time.ParseDuration(cfg.Intervals.HealthCheck)
	if err != nil {
		logJSON("fatal", "invalid health_check interval", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
	cveInterval, err := time.ParseDuration(cfg.Intervals.CVEScan)
	if err != nil {
		logJSON("fatal", "invalid cve_scan interval", map[string]string{"error": err.Error()})
		os.Exit(1)
	}

	var wg sync.WaitGroup

	// Repo watcher
	wg.Add(1)
	go func() {
		defer wg.Done()
		RunRepoWatcher(ctx, cfg.Repos, state, alerter, repoInterval)
	}()

	// Health checker
	wg.Add(1)
	go func() {
		defer wg.Done()
		RunHealthChecker(ctx, cfg.Repos, alerter, healthInterval)
	}()

	// CVE scanner
	wg.Add(1)
	go func() {
		defer wg.Done()
		RunCVEScanner(ctx, cfg.Repos, state, alerter, cveInterval)
	}()

	logJSON("info", "all watchers started", map[string]string{
		"repos":           fmt.Sprintf("%d", len(cfg.Repos)),
		"repo_interval":   cfg.Intervals.RepoCheck,
		"health_interval": cfg.Intervals.HealthCheck,
		"cve_interval":    cfg.Intervals.CVEScan,
	})

	sdNotify("READY=1")

	<-sigCh
	logJSON("info", "received shutdown signal, stopping watchers", nil)
	sdNotify("STOPPING=1")
	cancel()
	wg.Wait()

	if err := SaveState(state); err != nil {
		logJSON("error", "failed to save state on shutdown", map[string]string{"error": err.Error()})
	}

	logJSON("info", "carcinologistd stopped", nil)
}

func logJSON(level, msg string, fields map[string]string) {
	entry := map[string]string{
		"ts":    time.Now().UTC().Format(time.RFC3339),
		"level": level,
		"msg":   msg,
	}
	for k, v := range fields {
		entry[k] = v
	}
	data, _ := json.Marshal(entry)
	fmt.Fprintln(os.Stdout, string(data))
}

// sdNotify sends a notification to systemd if NOTIFY_SOCKET is set.
// This is a lightweight implementation that avoids heavy dependencies.
func sdNotify(state string) {
	socketAddr := os.Getenv("NOTIFY_SOCKET")
	if socketAddr == "" {
		return
	}

	conn, err := net.Dial("unixgram", socketAddr)
	if err != nil {
		return
	}
	defer conn.Close()
	_, _ = conn.Write([]byte(state))
}
