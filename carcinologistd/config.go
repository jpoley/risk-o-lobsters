package main

import (
	"fmt"
	"os"

	"github.com/BurntSushi/toml"
)

// Config is the top-level configuration for carcinologistd.
type Config struct {
	Telegram  TelegramConfig `toml:"telegram"`
	Repos     []RepoConfig   `toml:"repos"`
	Intervals IntervalConfig `toml:"intervals"`
}

// TelegramConfig holds Telegram Bot API credentials.
type TelegramConfig struct {
	BotToken string `toml:"bot_token"`
	ChatID   string `toml:"chat_id"`
}

// RepoConfig describes a monitored GitHub repository and its local service.
type RepoConfig struct {
	Name    string `toml:"name"`
	URL     string `toml:"url"`
	User    string `toml:"user"`
	Service string `toml:"service"`
}

// IntervalConfig defines polling intervals for each watcher.
type IntervalConfig struct {
	RepoCheck   string `toml:"repo_check"`
	HealthCheck string `toml:"health_check"`
	CVEScan     string `toml:"cve_scan"`
}

// LoadConfig reads and parses a TOML configuration file.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config file: %w", err)
	}

	if len(cfg.Repos) == 0 {
		return nil, fmt.Errorf("no repos configured")
	}

	// Set defaults for intervals if not specified
	if cfg.Intervals.RepoCheck == "" {
		cfg.Intervals.RepoCheck = "6h"
	}
	if cfg.Intervals.HealthCheck == "" {
		cfg.Intervals.HealthCheck = "5m"
	}
	if cfg.Intervals.CVEScan == "" {
		cfg.Intervals.CVEScan = "12h"
	}

	return &cfg, nil
}
