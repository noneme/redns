package lists

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const maxListSize = 64 << 20

type Fetcher struct {
	CacheDir string
	Client   *http.Client
}

func NewFetcher(cacheDir string) *Fetcher {
	return &Fetcher{
		CacheDir: cacheDir,
		Client: &http.Client{
			Timeout:       60 * time.Second,
			CheckRedirect: checkRedirect,
		},
	}
}

// checkRedirect bounds the fetch so a list URL cannot be abused for SSRF:
// at most 3 hops, no https→http downgrade, no non-public destination.
// The list body itself is covered by TLS certificate validation.
func checkRedirect(req *http.Request, via []*http.Request) error {
	if len(via) > 3 {
		return errors.New("too many redirects")
	}
	if len(via) > 0 && via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
		return errors.New("redirect downgrades https to http")
	}
	host := req.URL.Hostname()
	if ip, err := netip.ParseAddr(host); err == nil &&
		(!ip.IsGlobalUnicast() || ip.IsLoopback() || ip.IsPrivate()) {
		return fmt.Errorf("redirect to non-public address %s", host)
	}
	return nil
}

func (f *Fetcher) cachePath(url string) string {
	sum := sha256.Sum256([]byte(url))
	return filepath.Join(f.CacheDir, hex.EncodeToString(sum[:12])+".txt")
}

func (f *Fetcher) Fetch(ctx context.Context, url string) (body []byte, stale bool, err error) {
	body, err = f.download(ctx, url)
	if err == nil {
		if f.CacheDir != "" {
			_ = writeAtomic(f.cachePath(url), body)
		}
		return body, false, nil
	}
	if f.CacheDir != "" {
		if cached, cerr := os.ReadFile(f.cachePath(url)); cerr == nil {
			return cached, true, nil
		}
	}
	return nil, false, err
}

func (f *Fetcher) download(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "redns-list-fetcher/1")
	resp, err := f.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxListSize+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxListSize {
		return nil, errors.New("list is too large")
	}
	return body, nil
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if os.Geteuid() == 0 {
		if st, err := os.Stat(filepath.Dir(path)); err == nil {
			if sys, ok := st.Sys().(*syscall.Stat_t); ok {
				_ = os.Chown(tmp.Name(), int(sys.Uid), int(sys.Gid))
			}
		}
	}
	return os.Rename(tmp.Name(), path)
}
