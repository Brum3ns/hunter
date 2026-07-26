package provider

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"time"

	"hunter.local/assistant/gateway/internal/config"
)

var ErrProviderBodyTooLarge = errors.New("provider body exceeds limit")

const (
	maxProviderRequestBytes  = 1 << 20
	maxProviderResponseBytes = 512 << 10
)

func NewRestrictedHTTPClient() (*http.Client, error) {
	proxyURL, err := url.Parse(config.ProxyURL)
	if err != nil || proxyURL.Scheme != "http" || proxyURL.Host != "assistant-egress:3128" || proxyURL.User != nil {
		return nil, errors.New("invalid compiled provider proxy")
	}
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		Proxy: http.ProxyURL(proxyURL),
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if address != proxyURL.Host {
				return nil, errors.New("direct provider connection rejected")
			}
			return dialer.DialContext(ctx, network, address)
		},
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS13},
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          4,
		MaxIdleConnsPerHost:   2,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	return &http.Client{
		Transport: boundedTransport{
			next: transport, maxRequestBytes: maxProviderRequestBytes,
			maxResponseBytes: maxProviderResponseBytes,
		},
		Timeout:       90 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

type boundedTransport struct {
	next             http.RoundTripper
	maxRequestBytes  int64
	maxResponseBytes int64
}

func (transport boundedTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" || !slices.Contains([]string{"api.openai.com", "api.anthropic.com"}, request.URL.Hostname()) || (request.URL.Port() != "" && request.URL.Port() != "443") {
		return nil, errors.New("provider destination rejected")
	}
	if request.ContentLength > transport.maxRequestBytes {
		return nil, ErrProviderBodyTooLarge
	}
	if request.Body != nil && request.ContentLength < 0 {
		request.Body = &boundedReadCloser{reader: request.Body, closer: request.Body, remaining: transport.maxRequestBytes}
	}
	response, err := transport.next.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	if response.ContentLength > transport.maxResponseBytes {
		response.Body.Close()
		return nil, ErrProviderBodyTooLarge
	}
	response.Body = &boundedReadCloser{reader: response.Body, closer: response.Body, remaining: transport.maxResponseBytes}
	return response, nil
}

type boundedReadCloser struct {
	reader    io.Reader
	closer    io.Closer
	remaining int64
}

func (reader *boundedReadCloser) Read(destination []byte) (int, error) {
	if reader.remaining == 0 {
		var probe [1]byte
		n, err := reader.reader.Read(probe[:])
		if n > 0 {
			return 0, ErrProviderBodyTooLarge
		}
		return 0, err
	}
	if int64(len(destination)) > reader.remaining {
		destination = destination[:reader.remaining]
	}
	n, err := reader.reader.Read(destination)
	reader.remaining -= int64(n)
	return n, err
}

func (reader *boundedReadCloser) Close() error {
	return reader.closer.Close()
}
