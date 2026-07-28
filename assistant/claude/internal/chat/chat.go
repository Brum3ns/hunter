package chat

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
)

var (
	ErrLoginRequired = errors.New("claude login required")
	ErrMalformed     = errors.New("claude output malformed")
	ErrCLIFailed     = errors.New("claude cli failed")
)

type Request struct {
	Prompt    string
	SessionID string
}

type Response struct {
	SessionID string
	Reply     string
}

// cliResult mirrors `claude -p --output-format json` output.
type cliResult struct {
	SessionID string `json:"session_id"`
	Result    string `json:"result"`
	IsError   bool   `json:"is_error"`
}

func Run(ctx context.Context, bin string, req Request) (Response, error) {
	args := []string{"-p", req.Prompt, "--output-format", "json"}
	if req.SessionID != "" {
		args = append(args, "--resume", req.SessionID)
	}
	// No tools in Phase 1.
	args = append(args, "--allowedTools", "")
	out, err := exec.CommandContext(ctx, bin, args...).Output()

	var parsed cliResult
	if jsonErr := json.Unmarshal(out, &parsed); jsonErr != nil {
		return Response{}, ErrMalformed
	}
	if looksLikeLogin(parsed.Result) {
		return Response{}, ErrLoginRequired
	}
	if err != nil || parsed.IsError {
		return Response{}, ErrCLIFailed
	}
	if parsed.SessionID == "" || parsed.Result == "" {
		return Response{}, ErrMalformed
	}
	return Response{SessionID: parsed.SessionID, Reply: parsed.Result}, nil
}

func looksLikeLogin(s string) bool {
	l := strings.ToLower(s)
	return strings.Contains(l, "/login") || strings.Contains(l, "invalid api key") ||
		strings.Contains(l, "not logged in") || strings.Contains(l, "authentication")
}
