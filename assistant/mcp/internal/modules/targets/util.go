package targets

import (
	"net/url"
	"strconv"

	"hunter.local/assistant/mcp/internal/codec"
)

type listInput struct {
	Q       string `json:"q,omitempty"`
	Program string `json:"program,omitempty"`
	Status  string `json:"status,omitempty"`
	Page    int    `json:"page,omitempty"`
	Limit   int    `json:"limit,omitempty"`
}

type getInput struct {
	ID string `json:"id"`
}

// listQuery renders the closed list input as a stable, sorted query string.
func listQuery(in listInput) string {
	values := url.Values{}
	if in.Q != "" {
		values.Set("q", in.Q)
	}
	if in.Program != "" {
		values.Set("program", in.Program)
	}
	if in.Status != "" {
		values.Set("status", in.Status)
	}
	if in.Page > 0 {
		values.Set("page", strconv.Itoa(in.Page))
	}
	if in.Limit > 0 {
		values.Set("limit", strconv.Itoa(in.Limit))
	}
	return values.Encode()
}

func validID(id string) bool { return codec.SafeID.MatchString(id) }
