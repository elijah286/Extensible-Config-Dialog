package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRunFailsWhenNonEmptyWorklistRendersNothing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test creates a POSIX shell script")
	}

	tmp := t.TempDir()
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "Broken.vi"), []byte("vi"), 0o644); err != nil {
		t.Fatal(err)
	}

	worklist := filepath.Join(tmp, "worklist.tsv")
	if err := os.WriteFile(worklist, []byte("abcdef\tBroken.vi\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	lvctl := filepath.Join(tmp, "lvctl")
	if err := os.WriteFile(lvctl, []byte("#!/bin/sh\necho render failed >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("WORKSPACE", workspace)
	t.Setenv("WORKLIST", worklist)
	t.Setenv("OUT_BY_BLOB", filepath.Join(tmp, "by-blob"))
	t.Setenv("LVCTL", lvctl)
	t.Setenv("RENDER_TIMEOUT", "1s")

	err := run()
	if err == nil {
		t.Fatal("expected run to fail when every worklist item fails")
	}
	if !strings.Contains(err.Error(), "rendered 0 of 1 worklist item") {
		t.Fatalf("unexpected error: %v", err)
	}
}