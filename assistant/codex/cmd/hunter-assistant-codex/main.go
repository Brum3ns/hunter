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

	"hunter.local/assistant/codex/internal/chat"
)

const (
	listenAddress    = "0.0.0.0:8084"
	maxRequestBytes  = 64 << 10
	maxThreadIDBytes = 255
)

var defaultMCPTools = strings.Fields(
	"list_targets get_target " +
		"list_cves get_cve " +
		"list_vulnerabilities get_vulnerability " +
		"list_endpoints get_endpoint " +
		"list_programs get_program " +
		"list_templates get_template " +
		"list_jobs get_job " +
		"list_playbooks get_playbook " +
		"list_run_groups get_run_group " +
		"get_run list_run_events " +
		"create_whiterabbit_template create_ansible_playbook " +
		"edit_whiterabbit_template edit_ansible_playbook",
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "-healthcheck" {
		if err := checkHealth(); err != nil {
			os.Exit(1)
		}
		return
	}

	token := os.Getenv("ASSISTANT_CODEX_INGRESS_TOKEN")
	allowedHosts := splitList(os.Getenv("ASSISTANT_CODEX_ALLOWED_HOSTS"))
	if token == "" || len(allowedHosts) == 0 {
		log.Fatal("assistant-codex ingress configuration is incomplete")
	}

	timeout := time.Duration(intFromEnv("ASSISTANT_CODEX_TIMEOUT_SECONDS", 300)) * time.Second
	cfg := chat.Config{
		CodexHome:    "/home/codex/.codex",
		WorkingDir:   "/workspace",
		Timeout:      timeout,
		MCPURL:       os.Getenv("ASSISTANT_CODEX_MCP_URL"),
		MCPToken:     os.Getenv("ASSISTANT_CODEX_MCP_TOKEN"),
		AllowedTools: mcpToolsFromEnv(),
		SystemPrompt: systemPromptFromEnv(),
	}

	server := &http.Server{
		Addr:              listenAddress,
		Handler:           newServeMux(token, allowedHosts, "codex", cfg),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      timeout + 5*time.Second,
		IdleTimeout:       5 * time.Second,
		MaxHeaderBytes:    4 << 10,
	}

	log.Printf("assistant-codex listening on %s", listenAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal("assistant-codex server exited")
	}
}

func newServeMux(token string, allowedHosts []string, codexBin string, cfg chat.Config) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle("/healthz", newHealthHandler())
	mux.Handle("/chat", newChatHandler(token, allowedHosts, codexBin, cfg))
	return mux
}

func newHealthHandler() http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		setSecurityHeaders(response)
		if request.Method != http.MethodGet {
			response.Header().Set("Allow", http.MethodGet)
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		response.WriteHeader(http.StatusNoContent)
	})
}

type chatRequestBody struct {
	Prompt    string  `json:"prompt"`
	ThreadID  *string `json:"thread_id"`
	TurnGrant *string `json:"turn_grant"`
}

type chatResponseBody struct {
	ThreadID string `json:"thread_id"`
	Reply    string `json:"reply"`
}

func newChatHandler(token string, allowedHosts []string, codexBin string, cfg chat.Config) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		setSecurityHeaders(response)
		if request.Method != http.MethodPost {
			response.Header().Set("Allow", http.MethodPost)
			writeCode(response, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		if !slices.Contains(allowedHosts, request.Host) {
			writeCode(response, http.StatusForbidden, "host_not_allowed")
			return
		}
		if !authorizedBearer(request.Header.Get("Authorization"), token) {
			writeCode(response, http.StatusUnauthorized, "unauthorized")
			return
		}

		payload, err := io.ReadAll(io.LimitReader(request.Body, maxRequestBytes+1))
		if err != nil || len(payload) > maxRequestBytes {
			writeCode(response, http.StatusBadRequest, "invalid_request")
			return
		}
		var body chatRequestBody
		if !decodeExactJSON(payload, &body) || strings.TrimSpace(body.Prompt) == "" || !validOptionalThreadID(body.ThreadID) {
			writeCode(response, http.StatusBadRequest, "invalid_request")
			return
		}

		var threadID, turnGrant string
		if body.ThreadID != nil {
			threadID = *body.ThreadID
		}
		if body.TurnGrant != nil {
			turnGrant = *body.TurnGrant
		}

		result, err := chat.Run(request.Context(), codexBin, cfg, chat.Request{
			Prompt: body.Prompt, ThreadID: threadID, TurnGrant: turnGrant,
		})
		if err != nil {
			status, code := mapChatError(err)
			writeCode(response, status, code)
			return
		}

		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(response).Encode(chatResponseBody{ThreadID: result.ThreadID, Reply: result.Reply})
	})
}

func authorizedBearer(header, token string) bool {
	presented, hasScheme := strings.CutPrefix(header, "Bearer ")
	return token != "" && hasScheme && subtle.ConstantTimeCompare([]byte(presented), []byte(token)) == 1
}

func decodeExactJSON(payload []byte, destination any) bool {
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return false
	}
	var trailing any
	return decoder.Decode(&trailing) == io.EOF
}

func validOptionalThreadID(threadID *string) bool {
	if threadID == nil {
		return true
	}
	return len(*threadID) <= maxThreadIDBytes && strings.TrimSpace(*threadID) != ""
}

func mapChatError(err error) (int, string) {
	switch {
	case errors.Is(err, chat.ErrLoginRequired):
		return http.StatusServiceUnavailable, "codex_login_required"
	case errors.Is(err, chat.ErrUsageLimit):
		return http.StatusTooManyRequests, "codex_usage_limit"
	default:
		return http.StatusBadGateway, "codex_error"
	}
}

func setSecurityHeaders(response http.ResponseWriter) {
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("X-Content-Type-Options", "nosniff")
}

func writeCode(response http.ResponseWriter, status int, code string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]any{"error": map[string]string{"code": code}})
}

func splitList(value string) []string {
	fields := strings.Split(value, ",")
	list := make([]string, 0, len(fields))
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			list = append(list, trimmed)
		}
	}
	return list
}

func intFromEnv(name string, fallback int) int {
	value, err := strconv.Atoi(os.Getenv(name))
	if err != nil || value < 1 {
		return fallback
	}
	return value
}

func mcpToolsFromEnv() []string {
	requested := strings.Fields(os.Getenv("ASSISTANT_CODEX_MCP_TOOLS"))
	if len(requested) == 0 {
		requested = defaultMCPTools
	}
	requestedSet := make(map[string]struct{}, len(requested))
	for _, tool := range requested {
		requestedSet[tool] = struct{}{}
	}
	tools := make([]string, 0, len(defaultMCPTools))
	for _, reviewed := range defaultMCPTools {
		if _, ok := requestedSet[reviewed]; ok {
			tools = append(tools, reviewed)
		}
	}
	return tools
}

const defaultSystemPrompt = "You are the Hunter assistant. The mcp__hunter__ tools give you current, secret-safe Hunter data for targets, CVEs, vulnerabilities, sitemap endpoints, bug-bounty programs, and Control Center artifacts and history. Use the read tools whenever needed, with focused filters and the fewest calls that give a reliable result. Do not call tools for greetings, unrelated general knowledge, or speculative exploration. " +
	"When the user asks to create, write, add, or generate a Whiterabbit template/script or Ansible playbook, use the matching dedicated create tool without asking for confirmation. Create never overwrites an existing artifact. " +
	"Only use an edit tool when the user explicitly asks to edit, update, change, or fix an existing artifact. Read it first when its ID or current lock version is needed. Never delete, run, execute, launch, schedule, or send anything. Never use a generic shell, filesystem, network, credential, settings, or write capability."

func systemPromptFromEnv() string {
	if raw := strings.TrimSpace(os.Getenv("ASSISTANT_CODEX_SYSTEM_PROMPT")); raw != "" {
		return "Additional operator context:\n" + raw + "\n\nMandatory Hunter tool policy:\n" + defaultSystemPrompt
	}
	return defaultSystemPrompt
}

func checkHealth() error {
	client := &http.Client{
		Timeout:       2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get("http://127.0.0.1:8084/healthz")
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return errors.New("unhealthy")
	}
	return nil
}
