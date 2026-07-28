package provider

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"slices"
	"time"
)

var ErrProviderBodyTooLarge = errors.New("provider body exceeds limit")

const (
	maxProviderRequestBytes  = 1 << 20
	maxProviderResponseBytes = 512 << 10
)

// providerHosts is the only set of destinations this client will reach. It used
// to be enforced twice: once here and once by the squid allowlist the gateway was
// forced to proxy through. squid is gone, so this is now the sole enforcement
// point for provider egress — which is why the check is applied at BOTH layers
// below: `boundedTransport.RoundTrip` vets the request URL, and `DialContext`
// vets the address actually dialled, so a redirect or a rewritten URL cannot
// reach a host this list does not name.
var providerHosts = []string{"api.openai.com", "api.anthropic.com"}

func NewRestrictedHTTPClient() (*http.Client, error) {
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		// No Proxy: the gateway now reaches the provider directly. Explicitly nil
		// rather than omitted so no HTTP_PROXY/HTTPS_PROXY variable in the
		// container environment can silently redirect provider traffic.
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, errors.New("provider destination rejected")
			}
			if port != "443" || !slices.Contains(providerHosts, host) {
				return nil, errors.New("provider destination rejected")
			}
			return dialer.DialContext(ctx, network, address)
		},
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS13},
		ForceAttemptHTTP2:   true,
		MaxIdleConns:        4,
		MaxIdleConnsPerHost: 2,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
		// The Messages call is non-streaming, so the provider sends NO response
		// headers until the whole answer is generated. With adaptive thinking on
		// (Sonnet 5 default) a hard round routinely generates for well over 30s,
		// so a 30s header timeout aborted valid turns mid-think as
		// "http2: timeout awaiting response headers" -> provider_unavailable. It
		// must cover a full round; the turn context deadline is the real bound.
		ResponseHeaderTimeout: 300 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	return &http.Client{
		Transport: boundedTransport{
			next: transport, maxRequestBytes: maxProviderRequestBytes,
			maxResponseBytes: maxProviderResponseBytes,
		},
		// Caps a SINGLE provider round. Sonnet 5 runs adaptive thinking by default
		// and a hard drafting round can legitimately generate for well over 90s;
		// the old 90s ceiling aborted such a round mid-generation, which surfaced
		// as provider_unavailable AFTER the tokens were already billed. The turn's
		// own context deadline (maxTurnDuration, 5m) is the real bound and cancels
		// earlier when the whole turn is out of time; this just stops a slow-but-
		// valid round from being killed prematurely. DialContext (5s) and
		// TLSHandshakeTimeout (10s) still guard against a connection that never
		// establishes.
		Timeout:       300 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

type boundedTransport struct {
	next             http.RoundTripper
	maxRequestBytes  int64
	maxResponseBytes int64
}

func (transport boundedTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" || !slices.Contains(providerHosts, request.URL.Hostname()) || (request.URL.Port() != "" && request.URL.Port() != "443") {
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
