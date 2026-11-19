// opProxy's 1Password helper: holds one 1Password SDK client, authorized through the
// 1Password app, and runs the daemon's requests against it. It talks only to the daemon that
// started it, one JSON object per line on stdin and stdout, and exits when stdin closes.
//
// The daemon does everything else: which item a request means, whether it's allowed, and
// what `op` would print. Each method here is one SDK call, with the SDK's own JSON types.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/1password/onepassword-sdk-go"
)

type request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type reply struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *replyError     `json:"error,omitempty"`
}

// Kind is "unauthorized" (authorize again), "network" (try again later) or "failed".
type replyError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

type helper struct {
	mu     sync.Mutex
	client *onepassword.Client
}

func main() {
	h := &helper{}
	var out sync.Mutex
	var wg sync.WaitGroup
	// A few at a time: listing every vault is one call per vault.
	slots := make(chan struct{}, 4)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 64<<20)
	encoder := json.NewEncoder(os.Stdout)
	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			continue
		}
		wg.Add(1)
		slots <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-slots }()
			rep := reply{ID: req.ID}
			result, err := h.handle(context.Background(), req)
			if err != nil {
				rep.Error = classify(err)
			} else if rep.Result, err = json.Marshal(result); err != nil {
				rep.Error = &replyError{Kind: "failed", Message: err.Error()}
			}
			out.Lock()
			defer out.Unlock()
			_ = encoder.Encode(rep)
		}()
	}
	wg.Wait()
}

func (h *helper) handle(ctx context.Context, req request) (any, error) {
	if req.Method == "authorize" {
		return h.authorize(ctx, req.Params)
	}
	h.mu.Lock()
	client := h.client
	h.mu.Unlock()
	if client == nil {
		return nil, errNotAuthorized
	}
	var p struct {
		VaultID    string                       `json:"vaultId"`
		ItemID     string                       `json:"itemId"`
		Archived   bool                         `json:"archived"`
		Reference  string                       `json:"reference"`
		Attributes onepassword.FileAttributes   `json:"attributes"`
		Item       onepassword.Item             `json:"item"`
		Create     onepassword.ItemCreateParams `json:"create"`
	}
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, err
		}
	}
	switch req.Method {
	case "vaults":
		return client.VaultsAPI.List(ctx)
	case "vault":
		return client.VaultsAPI.GetOverview(ctx, p.VaultID)
	case "items":
		state := onepassword.NewItemListFilterTypeVariantByState(
			&onepassword.ItemListFilterByStateInner{Active: true, Archived: p.Archived})
		return client.ItemsAPI.List(ctx, p.VaultID, state)
	case "item":
		return client.ItemsAPI.Get(ctx, p.VaultID, p.ItemID)
	case "resolve":
		return client.SecretsAPI.Resolve(ctx, p.Reference)
	case "file":
		return client.ItemsAPI.Files().Read(ctx, p.VaultID, p.ItemID, p.Attributes)
	case "create":
		return client.ItemsAPI.Create(ctx, p.Create)
	case "put":
		return client.ItemsAPI.Put(ctx, p.Item)
	case "delete":
		return true, client.ItemsAPI.Delete(ctx, p.VaultID, p.ItemID)
	case "archive":
		return true, client.ItemsAPI.Archive(ctx, p.VaultID, p.ItemID)
	}
	return nil, fmt.Errorf("unknown method %q", req.Method)
}

// authorize makes the client and lists the vaults, which is when 1Password asks you. One
// authorization per process: authorizing again means starting a new helper.
func (h *helper) authorize(ctx context.Context, raw json.RawMessage) (any, error) {
	var p struct {
		Account string `json:"account"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.client != nil {
		return nil, errors.New("already authorized")
	}
	client, err := onepassword.NewClient(ctx,
		onepassword.WithDesktopAppIntegration(p.Account),
		onepassword.WithIntegrationInfo("opProxy", p.Version))
	if err != nil {
		return nil, err
	}
	vaults, err := client.VaultsAPI.List(ctx)
	if err != nil {
		return nil, err
	}
	h.client = client
	return map[string]int{"vaults": len(vaults)}, nil
}

var errNotAuthorized = errors.New("not authorized yet")

// classify tells the daemon whether 1Password ended the authorization, as opposed to a
// network outage or a request that failed on its own. The SDK reports most of these only
// as messages; these are the ones seen in practice.
func classify(err error) *replyError {
	message := err.Error()
	var expired *onepassword.DesktopSessionExpiredError
	var limited *onepassword.RateLimitExceededError
	lower := strings.ToLower(message)
	switch {
	case errors.As(err, &expired), errors.Is(err, errNotAuthorized),
		strings.Contains(lower, "invalid client id"),
		strings.Contains(lower, "connection channel is closed"):
		return &replyError{Kind: "unauthorized", Message: message}
	case errors.As(err, &limited),
		strings.Contains(lower, "error sending request"),
		strings.Contains(lower, "timed out"):
		return &replyError{Kind: "network", Message: message}
	}
	return &replyError{Kind: "failed", Message: message}
}
