package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"slices"
	"strings"
)

type grantContextKey struct{}

type Middleware struct {
	tokenDigest    [sha256.Size]byte
	allowedHosts   []string
	allowedOrigins []string
	maxBodyBytes   int64
}

func NewMiddleware(token string, allowedHosts, allowedOrigins []string, maxBodyBytes int64) *Middleware {
	return &Middleware{
		tokenDigest:    sha256.Sum256([]byte(token)),
		allowedHosts:   slices.Clone(allowedHosts),
		allowedOrigins: slices.Clone(allowedOrigins),
		maxBodyBytes:   maxBodyBytes,
	}
}

func (middleware *Middleware) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")

		if !slices.Contains(middleware.allowedHosts, request.Host) || !middleware.originAllowed(request.Header.Get("Origin")) {
			reject(response, http.StatusForbidden)
			return
		}
		if !middleware.authenticated(request.Header.Get("Authorization")) {
			reject(response, http.StatusUnauthorized)
			return
		}
		grant := request.Header.Get("X-Hunter-Turn-Grant")
		if !validGrant(grant) {
			reject(response, http.StatusForbidden)
			return
		}
		if request.Method == http.MethodPost {
			mediaType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
			if err != nil || mediaType != "application/json" {
				reject(response, http.StatusUnsupportedMediaType)
				return
			}
			if request.ContentLength > middleware.maxBodyBytes {
				reject(response, http.StatusRequestEntityTooLarge)
				return
			}
			body, tooLarge := readBounded(request.Body, middleware.maxBodyBytes)
			if tooLarge {
				reject(response, http.StatusRequestEntityTooLarge)
				return
			}
			request.Body = io.NopCloser(strings.NewReader(string(body)))
			request.ContentLength = int64(len(body))
		}

		ctx := context.WithValue(request.Context(), grantContextKey{}, grant)
		next.ServeHTTP(response, request.WithContext(ctx))
	})
}

func GrantFromContext(ctx context.Context) string {
	grant, _ := ctx.Value(grantContextKey{}).(string)
	return grant
}

func (middleware *Middleware) authenticated(header string) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) || strings.Contains(header[len(prefix):], " ") {
		return false
	}
	presented := sha256.Sum256([]byte(header[len(prefix):]))
	return subtle.ConstantTimeCompare(presented[:], middleware.tokenDigest[:]) == 1
}

func (middleware *Middleware) originAllowed(origin string) bool {
	return origin == "" || slices.Contains(middleware.allowedOrigins, origin)
}

func validGrant(grant string) bool {
	if len(grant) == 0 || len(grant) > 1024 {
		return false
	}
	return !strings.ContainsAny(grant, "\x00\r\n\t ")
}

func readBounded(reader io.Reader, max int64) ([]byte, bool) {
	if reader == nil {
		return nil, false
	}
	body, err := io.ReadAll(io.LimitReader(reader, max+1))
	return body, err != nil || int64(len(body)) > max
}

func reject(response http.ResponseWriter, status int) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]string{"error": "request_rejected"})
}
