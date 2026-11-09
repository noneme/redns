package web

import (
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const listUpdateSocket = "/run/redns/update.sock"

const listUpdateLimit = 256 << 10

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func runListUpdate(socketPath, mode string) (string, int, error) {
	if mode != "check" && mode != "apply" {
		return "", 2, errors.New("неизвестная команда")
	}
	conn, err := net.DialTimeout("unix", socketPath, 3*time.Second)
	if err != nil {
		return "", 0, fmt.Errorf("помощник обновления недоступен (%s): %w", socketPath, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Minute))
	if _, err := io.WriteString(conn, mode+"\n"); err != nil {
		return "", 0, err
	}
	raw, err := io.ReadAll(io.LimitReader(conn, listUpdateLimit+1))
	if err != nil {
		return "", 0, err
	}
	if len(raw) > listUpdateLimit {
		return "", 0, errors.New("ответ помощника слишком большой")
	}
	return parseListUpdate(string(raw))
}

func parseListUpdate(raw string) (string, int, error) {
	raw = ansi.ReplaceAllString(raw, "")
	line, rest, ok := strings.Cut(raw, "\n")
	code, okCode := strings.CutPrefix(line, "STATUS ")
	n, err := strconv.Atoi(strings.TrimSpace(code))
	if !ok || !okCode || err != nil {
		text := strings.TrimSpace(raw)
		if text == "" {
			text = "пустой ответ помощника"
		}
		return text, 1, nil
	}
	return strings.TrimRight(rest, "\n"), n, nil
}
