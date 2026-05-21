package mobile

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"strings"

	"masterdnsvpn-go/internal/client"
	"masterdnsvpn-go/internal/config"
)

var rawListenRe = struct {
	ip   *regexp.Regexp
	port *regexp.Regexp
}{
	ip:   regexp.MustCompile(`(?m)^\s*LISTEN_IP\s*=\s*"([^"]+)"`),
	port: regexp.MustCompile(`(?m)^\s*LISTEN_PORT\s*=\s*([0-9]+)`),
}

// StartRawInstance starts a tunnel instance from raw TOML and resolver text.
// It is intentionally tiny for gomobile clients: iOS can import the same
// client_config.toml used by Android without mirroring every config field in
// Swift.
func StartRawInstance(instanceID string, profileDir string, configToml string, resolversText string, listenAddr string) (retErr error) {
	defer func() {
		if r := recover(); r != nil {
			retErr = fmt.Errorf("panic in StartRawInstance: %v\n%s", r, debug.Stack())
		}
	}()

	if strings.TrimSpace(configToml) == "" {
		return errors.New("client config TOML is empty")
	}

	instancesMu.Lock()
	defer instancesMu.Unlock()
	if _, exists := instances[instanceID]; exists {
		return ErrAlreadyRunning
	}

	if err := os.MkdirAll(profileDir, 0o750); err != nil {
		return fmt.Errorf("failed to create profile directory: %w", err)
	}
	if err := os.WriteFile(ConfigFilePath(profileDir), []byte(configToml), 0o640); err != nil {
		return fmt.Errorf("failed to write raw config: %w", err)
	}
	if err := writeResolversFile(resolversText, filepath.Join(profileDir, "client_resolvers.txt")); err != nil {
		return fmt.Errorf("failed to write resolvers: %w", err)
	}

	configPath := ConfigFilePath(profileDir)
	logPath := filepath.Join(profileDir, "client.log")
	c, err := client.Bootstrap(configPath, logPath, config.ClientConfigOverrides{})
	if err != nil {
		return fmt.Errorf("bootstrap failed: %w", err)
	}
	c.PrintBanner()

	if strings.TrimSpace(listenAddr) == "" {
		listenAddr = detectRawListenAddr(configToml)
	}

	ctx, cancel := context.WithCancel(context.Background())
	h := &tunnelHandle{
		cl:         c,
		ctx:        ctx,
		cancel:     cancel,
		done:       make(chan struct{}),
		logStopCh:  make(chan struct{}),
		profileDir: profileDir,
		listenAddr: listenAddr,
	}

	go StartLogWatcher(logPath, h.logStopCh)
	go func() {
		defer close(h.done)
		defer func() {
			if r := recover(); r != nil {
				h.mu.Lock()
				h.lastErr = fmt.Errorf("panic in Run: %v\n%s", r, debug.Stack())
				h.mu.Unlock()
			}
		}()
		if runErr := c.Run(ctx); runErr != nil && !errors.Is(runErr, context.Canceled) {
			h.mu.Lock()
			h.lastErr = runErr
			h.mu.Unlock()
		}
	}()

	instances[instanceID] = h
	return nil
}

func detectRawListenAddr(configToml string) string {
	ip := "127.0.0.1"
	port := "10808"
	if match := rawListenRe.ip.FindStringSubmatch(configToml); len(match) == 2 && strings.TrimSpace(match[1]) != "" {
		ip = strings.TrimSpace(match[1])
	}
	if match := rawListenRe.port.FindStringSubmatch(configToml); len(match) == 2 && strings.TrimSpace(match[1]) != "" {
		port = strings.TrimSpace(match[1])
	}
	return ip + ":" + port
}
