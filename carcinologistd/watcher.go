package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// State tracks last-seen versions and scan times across daemon restarts.
type State struct {
	mu              sync.Mutex
	LastRelease     map[string]string `json:"last_release"`
	LastTag         map[string]string `json:"last_tag"`
	LastCVEScanTime time.Time         `json:"last_cve_scan_time"`
}

// NewState creates an empty state.
func NewState() *State {
	return &State{
		LastRelease: make(map[string]string),
		LastTag:     make(map[string]string),
	}
}

func stateFilePath() string {
	dir := os.Getenv("STATE_DIRECTORY")
	if dir != "" {
		return filepath.Join(dir, "state.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "/tmp"
	}
	dir = filepath.Join(home, ".local", "share", "carcinologistd")
	return filepath.Join(dir, "state.json")
}

// LoadState reads the persisted state from disk.
func LoadState() (*State, error) {
	path := stateFilePath()
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	if s.LastRelease == nil {
		s.LastRelease = make(map[string]string)
	}
	if s.LastTag == nil {
		s.LastTag = make(map[string]string)
	}
	return &s, nil
}

// SaveState persists state to disk.
func SaveState(s *State) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := stateFilePath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating state directory: %w", err)
	}

	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// githubClient returns an HTTP client and a function that builds requests
// with the GitHub token if available.
func githubRequest(url string) (*http.Request, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "carcinologistd/1.0")
	if token := os.Getenv("GITHUB_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return req, nil
}

// checkRateLimit inspects rate-limit headers and sleeps if needed.
func checkRateLimit(resp *http.Response) {
	remaining := resp.Header.Get("X-RateLimit-Remaining")
	if remaining == "" {
		return
	}
	rem, err := strconv.Atoi(remaining)
	if err != nil {
		return
	}
	if rem < 5 {
		resetStr := resp.Header.Get("X-RateLimit-Reset")
		if resetStr != "" {
			resetUnix, err := strconv.ParseInt(resetStr, 10, 64)
			if err == nil {
				sleepUntil := time.Unix(resetUnix, 0)
				wait := time.Until(sleepUntil)
				if wait > 0 && wait < 1*time.Hour {
					logJSON("warn", "GitHub rate limit low, sleeping", map[string]string{
						"remaining": remaining,
						"sleep":     wait.String(),
					})
					time.Sleep(wait)
				}
			}
		}
	}
}

// gitHubRelease represents the relevant fields from the GitHub releases API.
type gitHubRelease struct {
	TagName string `json:"tag_name"`
	Name    string `json:"name"`
	HTMLURL string `json:"html_url"`
}

// gitHubTag represents a tag from the GitHub tags API.
type gitHubTag struct {
	Name string `json:"name"`
}

// repoAPIBase extracts the API base from a configured URL.
// Supports both full API URLs (https://api.github.com/repos/owner/repo)
// and short GitHub URLs (https://github.com/owner/repo).
func repoAPIBase(configURL string) string {
	if strings.Contains(configURL, "api.github.com") {
		return configURL
	}
	// Convert https://github.com/owner/repo -> https://api.github.com/repos/owner/repo
	configURL = strings.TrimSuffix(configURL, "/")
	configURL = strings.Replace(configURL, "https://github.com/", "https://api.github.com/repos/", 1)
	return configURL
}

// RunRepoWatcher polls GitHub for new releases and tags on all configured repos.
func RunRepoWatcher(ctx context.Context, repos []RepoConfig, state *State, alerter *Alerter, interval time.Duration) {
	client := &http.Client{Timeout: 30 * time.Second}

	// Run immediately on start, then on interval
	checkAllRepos(ctx, client, repos, state, alerter)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logJSON("info", "repo watcher stopping", nil)
			return
		case <-ticker.C:
			checkAllRepos(ctx, client, repos, state, alerter)
		}
	}
}

func checkAllRepos(ctx context.Context, client *http.Client, repos []RepoConfig, state *State, alerter *Alerter) {
	for _, repo := range repos {
		if ctx.Err() != nil {
			return
		}
		checkLatestRelease(ctx, client, repo, state, alerter)
		checkLatestTag(ctx, client, repo, state, alerter)
	}
	if err := SaveState(state); err != nil {
		logJSON("error", "failed to save state after repo check", map[string]string{"error": err.Error()})
	}
}

func checkLatestRelease(ctx context.Context, client *http.Client, repo RepoConfig, state *State, alerter *Alerter) {
	apiBase := repoAPIBase(repo.URL)
	url := apiBase + "/releases/latest"

	req, err := githubRequest(url)
	if err != nil {
		logJSON("error", "failed to build release request", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}
	req = req.WithContext(ctx)

	resp, err := client.Do(req)
	if err != nil {
		logJSON("error", "failed to fetch latest release", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}
	defer resp.Body.Close()
	checkRateLimit(resp)

	if resp.StatusCode == http.StatusNotFound {
		// No releases for this repo, not an error
		return
	}
	if resp.StatusCode != http.StatusOK {
		logJSON("warn", "unexpected status from releases API", map[string]string{
			"repo":   repo.Name,
			"status": strconv.Itoa(resp.StatusCode),
		})
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		logJSON("error", "failed to read release response", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}

	var release gitHubRelease
	if err := json.Unmarshal(body, &release); err != nil {
		logJSON("error", "failed to parse release response", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}

	state.mu.Lock()
	lastSeen := state.LastRelease[repo.Name]
	if release.TagName != "" && release.TagName != lastSeen {
		state.LastRelease[repo.Name] = release.TagName
		state.mu.Unlock()

		logJSON("info", "new release detected", map[string]string{
			"repo":    repo.Name,
			"version": release.TagName,
			"url":     release.HTMLURL,
		})

		msg := fmt.Sprintf("*New Release: %s*\nVersion: `%s`\nName: %s\n[View release](%s)",
			repo.Name, release.TagName, release.Name, release.HTMLURL)
		alerter.Send(ctx, Alert{
			Type:    NewRelease,
			Service: repo.Name,
			Message: msg,
		})
	} else {
		state.mu.Unlock()
	}
}

func checkLatestTag(ctx context.Context, client *http.Client, repo RepoConfig, state *State, alerter *Alerter) {
	apiBase := repoAPIBase(repo.URL)
	url := apiBase + "/tags?per_page=1"

	req, err := githubRequest(url)
	if err != nil {
		logJSON("error", "failed to build tags request", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}
	req = req.WithContext(ctx)

	resp, err := client.Do(req)
	if err != nil {
		logJSON("error", "failed to fetch tags", map[string]string{"repo": repo.Name, "error": err.Error()})
		return
	}
	defer resp.Body.Close()
	checkRateLimit(resp)

	if resp.StatusCode != http.StatusOK {
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return
	}

	var tags []gitHubTag
	if err := json.Unmarshal(body, &tags); err != nil || len(tags) == 0 {
		return
	}

	state.mu.Lock()
	latestTag := tags[0].Name
	lastSeen := state.LastTag[repo.Name]
	if latestTag != "" && latestTag != lastSeen {
		state.LastTag[repo.Name] = latestTag
		state.mu.Unlock()

		// Only alert if we had a previous value (avoid alert storm on first run)
		if lastSeen != "" {
			logJSON("info", "new tag detected", map[string]string{
				"repo": repo.Name,
				"tag":  latestTag,
			})

			msg := fmt.Sprintf("*New Tag: %s*\nTag: `%s`\nPrevious: `%s`",
				repo.Name, latestTag, lastSeen)
			alerter.Send(ctx, Alert{
				Type:    NewRelease,
				Service: repo.Name,
				Message: msg,
			})
		}
	} else {
		state.mu.Unlock()
	}
}
