package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ResourceThresholds defines when to alert on high resource usage.
const (
	DefaultCPUThresholdPercent = 90.0
	DefaultMemThresholdMB     = 2048
)

// RunHealthChecker periodically checks systemd service status and resource usage.
func RunHealthChecker(ctx context.Context, repos []RepoConfig, alerter *Alerter, interval time.Duration) {
	// Run immediately, then on interval
	checkAllHealth(ctx, repos, alerter)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logJSON("info", "health checker stopping", nil)
			return
		case <-ticker.C:
			checkAllHealth(ctx, repos, alerter)
		}
	}
}

func checkAllHealth(ctx context.Context, repos []RepoConfig, alerter *Alerter) {
	for _, repo := range repos {
		if ctx.Err() != nil {
			return
		}
		checkServiceStatus(ctx, repo, alerter)
		checkResourceUsage(ctx, repo, alerter)
	}
}

// checkServiceStatus uses systemctl to check if a user service is active.
func checkServiceStatus(ctx context.Context, repo RepoConfig, alerter *Alerter) {
	// systemctl --user -M <user>@ status <service>
	cmd := exec.CommandContext(ctx, "systemctl", "--user", "-M", repo.User+"@", "is-active", repo.Service)
	output, err := cmd.Output()

	status := strings.TrimSpace(string(output))
	if err != nil || status != "active" {
		logJSON("warn", "service not active", map[string]string{
			"service": repo.Service,
			"user":    repo.User,
			"status":  status,
		})

		msg := fmt.Sprintf("*Service Down: %s*\nService: `%s`\nUser: `%s`\nStatus: `%s`",
			repo.Name, repo.Service, repo.User, status)
		alerter.Send(ctx, Alert{
			Type:    ServiceDown,
			Service: repo.Name,
			Message: msg,
		})
		return
	}

	logJSON("debug", "service healthy", map[string]string{
		"service": repo.Service,
		"user":    repo.User,
	})
}

// checkResourceUsage reads /proc to find the service's main PID and check its resource usage.
func checkResourceUsage(ctx context.Context, repo RepoConfig, alerter *Alerter) {
	// Use systemctl to get the main PID
	cmd := exec.CommandContext(ctx, "systemctl", "--user", "-M", repo.User+"@", "show", "-p", "MainPID", repo.Service)
	output, err := cmd.Output()
	if err != nil {
		return
	}

	pidStr := strings.TrimSpace(string(output))
	pidStr = strings.TrimPrefix(pidStr, "MainPID=")
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid == 0 {
		return
	}

	cpuPercent, memMB := getProcessStats(pid)

	if cpuPercent > DefaultCPUThresholdPercent {
		msg := fmt.Sprintf("*High CPU: %s*\nService: `%s`\nPID: `%d`\nCPU: `%.1f%%`",
			repo.Name, repo.Service, pid, cpuPercent)
		alerter.Send(ctx, Alert{
			Type:    HighResource,
			Service: repo.Name,
			Message: msg,
		})
	}

	if memMB > DefaultMemThresholdMB {
		msg := fmt.Sprintf("*High Memory: %s*\nService: `%s`\nPID: `%d`\nMemory: `%d MB`",
			repo.Name, repo.Service, pid, memMB)
		alerter.Send(ctx, Alert{
			Type:    HighResource,
			Service: repo.Name,
			Message: msg,
		})
	}
}

// getProcessStats reads /proc/<pid>/stat and /proc/<pid>/status for CPU and memory info.
func getProcessStats(pid int) (cpuPercent float64, memMB int) {
	// Read memory from /proc/<pid>/status (VmRSS line)
	statusPath := filepath.Join("/proc", strconv.Itoa(pid), "status")
	f, err := os.Open(statusPath)
	if err != nil {
		return 0, 0
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmRSS:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				kbVal, err := strconv.Atoi(fields[1])
				if err == nil {
					memMB = kbVal / 1024
				}
			}
		}
	}

	// Read CPU from /proc/<pid>/stat
	// Fields: pid comm state ppid pgrp session tty_nr tpgid flags
	//         minflt cminflt majflt cmajflt utime stime cutime cstime ...
	statPath := filepath.Join("/proc", strconv.Itoa(pid), "stat")
	statData, err := os.ReadFile(statPath)
	if err != nil {
		return 0, memMB
	}

	// Parse past the comm field (which may contain spaces/parens)
	statStr := string(statData)
	closeParen := strings.LastIndex(statStr, ")")
	if closeParen < 0 || closeParen+2 >= len(statStr) {
		return 0, memMB
	}
	fields := strings.Fields(statStr[closeParen+2:])
	// fields[0] = state, fields[11] = utime, fields[12] = stime (0-indexed from after comm)
	if len(fields) < 13 {
		return 0, memMB
	}

	utime, _ := strconv.ParseFloat(fields[11], 64)
	stime, _ := strconv.ParseFloat(fields[12], 64)

	// Get system uptime for CPU percentage calculation
	uptimeData, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, memMB
	}
	uptimeFields := strings.Fields(string(uptimeData))
	if len(uptimeFields) < 1 {
		return 0, memMB
	}
	uptime, _ := strconv.ParseFloat(uptimeFields[0], 64)

	// Get clock ticks per second (typically 100 on Linux)
	clkTck := 100.0

	// CPU% = (utime + stime) / clk_tck / uptime * 100
	if uptime > 0 {
		totalCPUSeconds := (utime + stime) / clkTck
		cpuPercent = (totalCPUSeconds / uptime) * 100.0
	}

	return cpuPercent, memMB
}
