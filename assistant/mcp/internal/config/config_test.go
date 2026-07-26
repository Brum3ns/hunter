package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadSecretRequiresARegularOwnerReadOnlyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "token")
	if err := os.WriteFile(path, []byte("secret-token\n"), 0o400); err != nil {
		t.Fatal(err)
	}

	got, err := ReadSecret(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != "secret-token" {
		t.Fatalf("got %q", got)
	}

	if err := os.Chmod(path, 0o440); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecret(path); err == nil {
		t.Fatal("accepted a group-readable secret")
	}
}

func TestReadSecretRejectsSymlinksEmptyAndOversizedFiles(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("token"), 0o400); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(dir, "link")
	if err := os.Symlink(target, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecret(symlink); err == nil {
		t.Fatal("accepted a symlink")
	}

	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, nil, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecret(empty); err == nil {
		t.Fatal("accepted an empty secret")
	}

	large := filepath.Join(dir, "large")
	if err := os.WriteFile(large, make([]byte, maxSecretBytes+1), 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecret(large); err == nil {
		t.Fatal("accepted an oversized secret")
	}
}
