package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
)

type Middleware struct {
	tokenDigest  [sha256.Size]byte
	maxBodyBytes int64
}

func NewMiddleware(token string, maxBodyBytes int64) *Middleware {
	return &Middleware{
		tokenDigest:  sha256.Sum256([]byte(token)),
		maxBodyBytes: maxBodyBytes,
	}
}

func (middleware *Middleware) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("X-Content-Type-Options", "nosniff")

		if !middleware.authenticated(request.Header.Get("Authorization")) {
			reject(response, http.StatusUnauthorized)
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

		next.ServeHTTP(response, request)
	})
}

func (middleware *Middleware) authenticated(header string) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) ||
		header[len(prefix):] == "" ||
		strings.ContainsAny(header[len(prefix):], "\x00\r\n\t ") {
		return false
	}
	presented := sha256.Sum256([]byte(header[len(prefix):]))
	return subtle.ConstantTimeCompare(presented[:], middleware.tokenDigest[:]) == 1
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
