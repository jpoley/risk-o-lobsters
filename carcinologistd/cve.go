package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// gitHubAdvisory represents a subset of the GitHub Security Advisory API response.
type gitHubAdvisory struct {
	GHSAID      string `json:"ghsa_id"`
	CVEID       string `json:"cve_id"`
	Summary     string `json:"summary"`
	Severity    string `json:"severity"`
	HTMLURL     string `json:"html_url"`
	PublishedAt string `json:"published_at"`
	Vulnerabilities []struct {
		Package struct {
			Ecosystem string `json:"ecosystem"`
			Name      string `json:"name"`
		} `json:"package"`
	} `json:"vulnerabilities"`
}

// RunCVEScanner periodically queries the GitHub Advisory Database for advisories
// related to the monitored repos/packages.
func RunCVEScanner(ctx context.Context, repos []RepoConfig, state *State, alerter *Alerter, interval time.Duration) {
	client := &http.Client{Timeout: 30 * time.Second}

	// Run immediately, then on interval
	scanCVEs(ctx, client, repos, state, alerter)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logJSON("info", "CVE scanner stopping", nil)
			return
		case <-ticker.C:
			scanCVEs(ctx, client, repos, state, alerter)
		}
	}
}

func scanCVEs(ctx context.Context, client *http.Client, repos []RepoConfig, state *State, alerter *Alerter) {
	state.mu.Lock()
	lastScan := state.LastCVEScanTime
	state.mu.Unlock()

	// Query for each ecosystem that our repos might belong to
	ecosystems := []string{"npm", "pip", "cargo", "go"}

	for _, ecosystem := range ecosystems {
		if ctx.Err() != nil {
			return
		}
		advisories := fetchAdvisories(ctx, client, ecosystem, lastScan)
		for _, adv := range advisories {
			if matchesMonitoredRepo(adv, repos) {
				cveID := adv.CVEID
				if cveID == "" {
					cveID = adv.GHSAID
				}

				logJSON("info", "CVE found for monitored package", map[string]string{
					"cve":      cveID,
					"severity": adv.Severity,
					"summary":  adv.Summary,
				})

				msg := fmt.Sprintf("*CVE Alert*\nID: `%s`\nSeverity: *%s*\nSummary: %s\n[View advisory](%s)",
					cveID, strings.ToUpper(adv.Severity), adv.Summary, adv.HTMLURL)

				// Determine which service this affects
				service := "unknown"
				for _, v := range adv.Vulnerabilities {
					for _, repo := range repos {
						if matchesPackageName(v.Package.Name, repo) {
							service = repo.Name
							break
						}
					}
				}

				alerter.Send(ctx, Alert{
					Type:    CVEFound,
					Service: service,
					Message: msg,
				})
			}
		}
	}

	state.mu.Lock()
	state.LastCVEScanTime = time.Now()
	state.mu.Unlock()

	if err := SaveState(state); err != nil {
		logJSON("error", "failed to save state after CVE scan", map[string]string{"error": err.Error()})
	}
}

func fetchAdvisories(ctx context.Context, client *http.Client, ecosystem string, since time.Time) []gitHubAdvisory {
	params := url.Values{}
	params.Set("ecosystem", ecosystem)
	params.Set("per_page", "100")
	if !since.IsZero() {
		params.Set("published", ">"+since.Format("2006-01-02"))
	}

	apiURL := "https://api.github.com/advisories?" + params.Encode()

	req, err := githubRequest(apiURL)
	if err != nil {
		logJSON("error", "failed to build advisories request", map[string]string{"error": err.Error()})
		return nil
	}
	req = req.WithContext(ctx)

	resp, err := client.Do(req)
	if err != nil {
		logJSON("error", "failed to fetch advisories", map[string]string{
			"ecosystem": ecosystem,
			"error":     err.Error(),
		})
		return nil
	}
	defer resp.Body.Close()
	checkRateLimit(resp)

	if resp.StatusCode != http.StatusOK {
		logJSON("warn", "advisories API returned non-200", map[string]string{
			"ecosystem": ecosystem,
			"status":    fmt.Sprintf("%d", resp.StatusCode),
		})
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	var advisories []gitHubAdvisory
	if err := json.Unmarshal(body, &advisories); err != nil {
		logJSON("error", "failed to parse advisories", map[string]string{
			"ecosystem": ecosystem,
			"error":     err.Error(),
		})
		return nil
	}

	return advisories
}

// matchesMonitoredRepo checks if an advisory affects any of the monitored repos.
func matchesMonitoredRepo(adv gitHubAdvisory, repos []RepoConfig) bool {
	// Check if any vulnerability package matches a monitored repo
	for _, v := range adv.Vulnerabilities {
		for _, repo := range repos {
			if matchesPackageName(v.Package.Name, repo) {
				return true
			}
		}
	}

	// Also check summary text for repo names
	summaryLower := strings.ToLower(adv.Summary)
	for _, repo := range repos {
		if strings.Contains(summaryLower, strings.ToLower(repo.Name)) {
			return true
		}
	}

	return false
}

// matchesPackageName checks if a package name matches a monitored repo.
func matchesPackageName(pkgName string, repo RepoConfig) bool {
	pkgLower := strings.ToLower(pkgName)
	repoLower := strings.ToLower(repo.Name)

	// Direct name match
	if pkgLower == repoLower {
		return true
	}

	// Check if package name contains the repo name
	if strings.Contains(pkgLower, repoLower) {
		return true
	}

	// Extract org/repo from URL and check
	// e.g., https://api.github.com/repos/openclaw/openclaw -> openclaw/openclaw
	urlParts := strings.Split(repo.URL, "/")
	if len(urlParts) >= 2 {
		orgRepo := strings.ToLower(urlParts[len(urlParts)-2] + "/" + urlParts[len(urlParts)-1])
		if strings.Contains(pkgLower, orgRepo) {
			return true
		}
	}

	return false
}
