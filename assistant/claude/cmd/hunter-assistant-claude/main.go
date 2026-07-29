package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"hunter.local/assistant/claude/internal/chat"
)

const listenAddress = "0.0.0.0:8083"

// maxRequestBytes bounds the /chat body. A prompt plus an optional session id
// comfortably fits well under this; it exists as a slow-loris / oversized-body
// defence, not as a meaningful product limit.
const maxRequestBytes = 64 << 10

// defaultMCPTools is the read-only mcp__hunter__* allowlist used when
// ASSISTANT_CLAUDE_MCP_TOOLS is unset. It MUST contain only read tools —
// never a built-in (Bash/Write/Edit/Read/WebFetch/...) and never a write/
// execute/send MCP tool; see AGENTS.md's assistant capability change rule.
var defaultMCPTools = strings.Fields(
	"mcp__hunter__list_targets mcp__hunter__get_target " +
		"mcp__hunter__list_cves mcp__hunter__get_cve " +
		"mcp__hunter__list_vulnerabilities mcp__hunter__get_vulnerability " +
		"mcp__hunter__list_endpoints mcp__hunter__get_endpoint " +
		"mcp__hunter__list_programs mcp__hunter__get_program " +
		"mcp__hunter__list_templates mcp__hunter__get_template " +
		"mcp__hunter__list_jobs mcp__hunter__get_job " +
		"mcp__hunter__list_playbooks mcp__hunter__get_playbook " +
		"mcp__hunter__list_run_groups mcp__hunter__get_run_group " +
		"mcp__hunter__get_run mcp__hunter__list_run_events",
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "-healthcheck" {
		if err := checkHealth(); err != nil {
			os.Exit(1)
		}
		return
	}

	token := os.Getenv("ASSISTANT_CLAUDE_INGRESS_TOKEN")
	allowedHosts := splitList(os.Getenv("ASSISTANT_CLAUDE_ALLOWED_HOSTS"))
	if token == "" {
		log.Print("WARNING: ASSISTANT_CLAUDE_INGRESS_TOKEN is empty — /chat ingress auth is DISABLED; the service trusts the internal network only. Set a token to require a bearer credential.")
	}

	// The claude CLI can take a while on a real turn (model latency + no
	// tools means no early return); this is the one knob that lets an
	// operator raise it without a rebuild, mirroring intFromEnv's role in
	// the gateway's config.
	timeout := time.Duration(intFromEnv("ASSISTANT_CLAUDE_TIMEOUT_SECONDS", 120)) * time.Second

	mcpCfg := chat.Config{
		MCPURL:       os.Getenv("ASSISTANT_CLAUDE_MCP_URL"),
		MCPToken:     os.Getenv("ASSISTANT_CLAUDE_MCP_TOKEN"),
		AllowedTools: mcpToolsFromEnv(),
		SystemPrompt: systemPromptFromEnv(),
	}

	server := &http.Server{
		Addr:              listenAddress,
		Handler:           newServeMux(token, allowedHosts, "claude", mcpCfg),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       timeout,
		WriteTimeout:      timeout,
		IdleTimeout:       5 * time.Second,
		MaxHeaderBytes:    4 << 10,
	}

	log.Printf("assistant-claude listening on %s", listenAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal("assistant-claude server exited")
	}
}

// newServeMux builds the one mux the process serves. There is no
// MCP/processor/readiness gate here (unlike the gateway) — the official
// claude CLI is either usable or it errors per-request, so /chat is always
// mounted and always answers.
func newServeMux(token string, allowedHosts []string, claudeBin string, mcpCfg chat.Config) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("/healthz", newHealthHandler())
	mux.Handle("/chat", newChatHandler(token, allowedHosts, claudeBin, mcpCfg))
	return mux
}

func newHealthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		if request.Method != http.MethodGet {
			response.Header().Set("Allow", http.MethodGet)
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		response.WriteHeader(http.StatusNoContent)
	})
	return mux
}

type chatRequestBody struct {
	Prompt    string  `json:"prompt"`
	SessionID *string `json:"session_id"`
	// TurnGrant is the per-turn credential Rails issues (Issuer.call). It is
	// optional: an absent or empty grant simply disables MCP for the turn
	// (see chat.buildInvocation), it is never treated as a request error.
	TurnGrant *string `json:"turn_grant"`
}

type chatResponseBody struct {
	SessionID string `json:"session_id"`
	Reply     string `json:"reply"`
}

// newChatHandler builds the authenticated POST /chat route: the checks run in
// a fixed order — method, host, bearer token, then body — so that an
// unauthenticated or disallowed request is rejected before its body is ever
// read or a claude process is ever spawned. claudeBin names the executable to
// run ("claude" in prod; a fake or harmless binary like "true" in tests).
func newChatHandler(token string, allowedHosts []string, claudeBin string, mcpCfg chat.Config) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost {
			writeCode(response, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		if !slices.Contains(allowedHosts, request.Host) {
			writeCode(response, http.StatusForbidden, "host_not_allowed")
			return
		}
		// An empty configured token disables ingress auth entirely: the service
		// then trusts the network boundary alone (assistant-rails-claude is an
		// internal-only Docker network whose sole other member is web, and the
		// service publishes no host port). This is the intended single-user /
		// local-dev posture; a deployment that wants the second lock sets a
		// non-empty ASSISTANT_CLAUDE_INGRESS_TOKEN and the check below enforces
		// it. main() logs loudly at startup when auth is disabled.
		if token != "" {
			// CutPrefix, not TrimPrefix: TrimPrefix returns the header unchanged
			// when the scheme is absent, which would accept a bare
			// "Authorization: <token>" as though it were "Bearer <token>".
			// ConstantTimeCompare defends the token comparison against a timing
			// side channel; the short-circuit on a missing scheme only reveals
			// whether the caller sent one, which is not a secret.
			presented, hasScheme := strings.CutPrefix(request.Header.Get("Authorization"), "Bearer ")
			if !hasScheme || subtle.ConstantTimeCompare([]byte(presented), []byte(token)) != 1 {
				writeCode(response, http.StatusUnauthorized, "unauthorized")
				return
			}
		}

		payload, err := io.ReadAll(io.LimitReader(request.Body, maxRequestBytes+1))
		if err != nil || len(payload) > maxRequestBytes {
			writeCode(response, http.StatusBadRequest, "invalid_request")
			return
		}
		var body chatRequestBody
		if err := json.Unmarshal(payload, &body); err != nil || strings.TrimSpace(body.Prompt) == "" {
			writeCode(response, http.StatusBadRequest, "invalid_request")
			return
		}
		var sessionID string
		if body.SessionID != nil {
			sessionID = *body.SessionID
		}
		var turnGrant string
		if body.TurnGrant != nil {
			turnGrant = *body.TurnGrant
		}

		result, err := chat.Run(request.Context(), claudeBin, mcpCfg, chat.Request{Prompt: body.Prompt, SessionID: sessionID, TurnGrant: turnGrant})
		if err != nil {
			status, code := mapChatError(err)
			writeCode(response, status, code)
			return
		}

		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(response).Encode(chatResponseBody{SessionID: result.SessionID, Reply: result.Reply})
	})
}

// mapChatError turns a chat.Run error into the stable code Rails matches on
// and an HTTP status. It never includes CLI output or any credential — only
// one of a small fixed set of codes ever leaves this process on failure.
func mapChatError(err error) (int, string) {
	switch {
	case errors.Is(err, chat.ErrLoginRequired):
		// The operator needs to run `claude login` on the persistent volume;
		// this is a transient, operator-actionable state, not a caller error.
		return http.StatusServiceUnavailable, "claude_login_required"
	case errors.Is(err, chat.ErrMalformed):
		return http.StatusBadGateway, "claude_malformed_response"
	case errors.Is(err, chat.ErrCLIFailed):
		return http.StatusBadGateway, "claude_error"
	default:
		return http.StatusBadGateway, "claude_error"
	}
}

func writeCode(response http.ResponseWriter, status int, code string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]any{"error": map[string]string{"code": code}})
}

// splitList parses a comma-separated environment value into its trimmed,
// non-empty entries. An empty or all-blank input yields an empty slice, not a
// slice holding one empty string, so an unset allowlist denies everything
// instead of accidentally matching an empty Host.
func splitList(value string) []string {
	if value == "" {
		return nil
	}
	fields := strings.Split(value, ",")
	list := make([]string, 0, len(fields))
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			list = append(list, trimmed)
		}
	}
	return list
}

// intFromEnv reads a positive integer environment variable, falling back to
// fallback when it is unset, empty, or fails to parse as one.
func intFromEnv(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 {
		return fallback
	}
	return value
}

// mcpToolsFromEnv reads ASSISTANT_CLAUDE_MCP_TOOLS as a whitespace-separated
// tool list, falling back to defaultMCPTools when it is unset or empty —
// mirroring intFromEnv's fallback-on-empty convention for this file's other
// env-derived settings. The result is always filtered to the mcp__hunter__
// prefix (see filterHunterMCPTools) so a misconfigured operator override can
// never widen --allowedTools to a built-in or non-hunter MCP tool.
func mcpToolsFromEnv() []string {
	raw := os.Getenv("ASSISTANT_CLAUDE_MCP_TOOLS")
	if raw == "" {
		return filterHunterMCPTools(defaultMCPTools)
	}
	return filterHunterMCPTools(strings.Fields(raw))
}

// hunterMCPToolPrefix is the only prefix ever allowed into --allowedTools.
const hunterMCPToolPrefix = "mcp__hunter__"

// filterHunterMCPTools drops any entry that is not exactly prefixed with
// mcp__hunter__, so the CLI allowlist can never carry a built-in (Bash,
// Write, ...) or a non-hunter MCP tool regardless of what
// ASSISTANT_CLAUDE_MCP_TOOLS is set to. If nothing survives, it returns an
// empty slice rather than substituting any other tool list — the backend
// already treats an empty/absent config as "no MCP for this turn".
func filterHunterMCPTools(tools []string) []string {
	filtered := make([]string, 0, len(tools))
	for _, tool := range tools {
		if strings.HasPrefix(tool, hunterMCPToolPrefix) {
			filtered = append(filtered, tool)
		}
	}
	return filtered
}

// defaultSystemPrompt is the tool-use policy appended to the CLI's default
// system prompt on MCP-enabled turns. It keeps the model from calling a
// read tool unless the user's message explicitly asks for a Hunter data
// lookup — without it, the model calls the tools speculatively and every
// turn pays the multi-hop MCP round trip.
const defaultSystemPrompt = "You are the Hunter assistant. You have read-only tools (named mcp__hunter__*) that look up live data in Hunter: targets, CVEs, vulnerabilities, sitemap endpoints, bug-bounty programs, and Control Center templates/jobs/ansible runs. STRICT TOOL POLICY: never call any tool unless the user's most recent message EXPLICITLY asks you to look up, search, list, count, fetch, or show Hunter data. For greetings, small talk, general questions, definitions, or anything that does not explicitly request a Hunter data lookup, answer directly from your own knowledge and DO NOT call any tool. If you are unsure whether the user wants a lookup, do NOT call a tool — answer briefly and offer to look it up if they want. Never call a tool speculatively, proactively, or to double-check. When a lookup IS explicitly requested, make the fewest tool calls needed."

// systemPromptFromEnv returns the tool-use policy appended via
// --append-system-prompt. ASSISTANT_CLAUDE_SYSTEM_PROMPT overrides it when
// set; an explicit empty value disables the append (operator opt-out), which
// is why this distinguishes unset from empty rather than falling back on "".
func systemPromptFromEnv() string {
	if raw, ok := os.LookupEnv("ASSISTANT_CLAUDE_SYSTEM_PROMPT"); ok {
		return raw
	}
	return defaultSystemPrompt
}

func checkHealth() error {
	client := &http.Client{
		Timeout:       2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get("http://127.0.0.1:8083/healthz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("unhealthy")
	}
	return nil
}
