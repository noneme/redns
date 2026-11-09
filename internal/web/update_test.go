package web

import (
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestParseListUpdate(t *testing.T) {
	out, code, err := parseListUpdate("STATUS 0\nвсё актуально\n")
	if err != nil || code != 0 || out != "всё актуально" {
		t.Fatalf("got %q %d %v", out, code, err)
	}
	out, code, err = parseListUpdate("\x1b[31mОшибка:\x1b[0m нет сети")
	if err != nil || code != 1 || out != "Ошибка: нет сети" {
		t.Fatalf("bad reply: %q %d %v", out, code, err)
	}
}

func TestRunListUpdate(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "update.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 16)
		n, _ := c.Read(buf)
		if string(buf[:n]) != "check\n" {
			_, _ = c.Write([]byte("STATUS 2\nbad\n"))
			return
		}
		_, _ = c.Write([]byte("STATUS 0\nобновлять нечего\n"))
	}()
	out, code, err := runListUpdate(sock, "check")
	if err != nil || code != 0 || out != "обновлять нечего" {
		t.Fatalf("got %q %d %v", out, code, err)
	}
}
