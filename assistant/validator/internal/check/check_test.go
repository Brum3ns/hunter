package check

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

const validSource = "---\n- hosts: workers\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug:\n        msg: ready\n"

type runnerFunc func(context.Context, Invocation) Execution

func (function runnerFunc) Run(ctx context.Context, invocation Invocation) Execution {
	return function(ctx, invocation)
}

func TestCheckerUsesOnePrivateWorkspaceAndRemovesIt(t *testing.T) {
	root := t.TempDir()
	runner := runnerFunc(func(_ context.Context, invocation Invocation) Execution {
		if invocation.Path != "/usr/bin/ansible-playbook" {
			t.Fatalf("path=%q", invocation.Path)
		}
		wantArgs := []string{"--syntax-check", "--inventory", "localhost,", "playbook.yml"}
		if !slices.Equal(invocation.Args, wantArgs) {
			t.Fatalf("args=%v", invocation.Args)
		}
		workspaceInfo, err := os.Stat(invocation.Dir)
		if err != nil || workspaceInfo.Mode().Perm() != 0o700 {
			t.Fatalf("workspace info=%v err=%v", workspaceInfo, err)
		}
		body, err := os.ReadFile(filepath.Join(invocation.Dir, "playbook.yml"))
		if err != nil || string(body) != validSource {
			t.Fatalf("playbook body=%q err=%v", body, err)
		}
		playbookInfo, _ := os.Stat(filepath.Join(invocation.Dir, "playbook.yml"))
		if playbookInfo.Mode().Perm() != 0o600 {
			t.Fatalf("playbook mode=%o", playbookInfo.Mode().Perm())
		}
		entries, err := os.ReadDir(invocation.Dir)
		if err != nil {
			t.Fatal(err)
		}
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		slices.Sort(names)
		wantNames := []string{"home", "local", "playbook.yml", "remote", "tmp"}
		if !slices.Equal(names, wantNames) {
			t.Fatalf("workspace entries=%v", names)
		}
		wantEnvironment := []string{
			"ANSIBLE_CONFIG=/etc/ansible/ansible.cfg",
			"HOME=" + filepath.Join(invocation.Dir, "home"),
			"ANSIBLE_LOCAL_TEMP=" + filepath.Join(invocation.Dir, "local"),
			"ANSIBLE_REMOTE_TEMP=" + filepath.Join(invocation.Dir, "remote"),
			"TMPDIR=" + filepath.Join(invocation.Dir, "tmp"),
			"PATH=/usr/bin:/bin",
			"LANG=C.UTF-8",
			"LC_ALL=C.UTF-8",
			"ANSIBLE_NOCOLOR=1",
			"PYTHONDONTWRITEBYTECODE=1",
			"PYTHONNOUSERSITE=1",
			"PYTHONSAFEPATH=1",
		}
		if !slices.Equal(invocation.Env, wantEnvironment) {
			t.Fatalf("environment=%q", invocation.Env)
		}
		return Execution{ExitCode: 0}
	})

	result := Checker{WorkRoot: root, Runner: runner}.Check(context.Background(), validSource)

	if result.Status != "valid" || len(result.Codes) != 0 {
		t.Fatalf("result=%+v", result)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("retained workspaces=%v err=%v", entries, err)
	}
}

func TestCheckerRejectsOversizedSourceBeforeStartingAProcess(t *testing.T) {
	called := false
	runner := runnerFunc(func(context.Context, Invocation) Execution {
		called = true
		return Execution{}
	})

	result := Checker{WorkRoot: t.TempDir(), Runner: runner}.Check(
		context.Background(), strings.Repeat("x", 65_537),
	)

	if result.Status != "failed" || !slices.Contains(result.Codes, "validator_source_rejected") || called {
		t.Fatalf("result=%+v called=%v", result, called)
	}
}

func TestCheckerReturnsOnlyStableCodesForSyntaxErrorsAndOutputOverflow(t *testing.T) {
	tests := []struct {
		name      string
		execution Execution
		code      string
	}{
		{name: "syntax", execution: Execution{ExitCode: 2, Stderr: []byte("/secret/work/playbook.yml: password=hunter")}, code: "ansible_syntax_invalid"},
		{name: "overflow", execution: Execution{ExitCode: 1, Truncated: true, Stderr: []byte("private output")}, code: "validator_output_too_large"},
		{name: "timeout", execution: Execution{ExitCode: -1, TimedOut: true}, code: "validator_timeout"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := runnerFunc(func(context.Context, Invocation) Execution { return test.execution })
			result := Checker{WorkRoot: t.TempDir(), Runner: runner, Timeout: 10 * time.Millisecond}.Check(context.Background(), validSource)

			if result.Status == "valid" || !slices.Equal(result.Codes, []string{test.code}) {
				t.Fatalf("result=%+v", result)
			}
			if strings.Contains(strings.Join(result.Codes, " "), "secret") || strings.Contains(strings.Join(result.Codes, " "), "password") {
				t.Fatalf("unredacted result=%+v", result)
			}
		})
	}
}

func TestOSRunnerHonorsCancellationBeforeStart(t *testing.T) {
	contextCanceled, cancel := context.WithCancel(context.Background())
	cancel()
	execution := (OSRunner{}).Run(contextCanceled, Invocation{Path: os.Args[0], Args: []string{"-test.run=never"}})
	if !execution.TimedOut && !errors.Is(execution.Err, context.Canceled) {
		t.Fatalf("execution=%+v", execution)
	}
}

func TestOSRunnerCapsBothOutputs(t *testing.T) {
	if os.Getenv("HUNTER_VALIDATOR_TEST_HELPER") == "output" {
		_, _ = os.Stdout.Write(bytes.Repeat([]byte("o"), maxOutputBytes+100))
		_, _ = os.Stderr.Write(bytes.Repeat([]byte("e"), maxOutputBytes+100))
		os.Exit(0)
	}
	execution := (OSRunner{}).Run(context.Background(), Invocation{
		Path: os.Args[0],
		Args: []string{"-test.run=TestOSRunnerCapsBothOutputs"},
		Env:  append(os.Environ(), "HUNTER_VALIDATOR_TEST_HELPER=output"),
	})
	if execution.ExitCode != 0 || !execution.Truncated || len(execution.Stdout) != maxOutputBytes || len(execution.Stderr) != maxOutputBytes {
		t.Fatalf("execution exit=%d truncated=%v stdout=%d stderr=%d err=%v", execution.ExitCode, execution.Truncated, len(execution.Stdout), len(execution.Stderr), execution.Err)
	}
}

func TestOSRunnerKillsTheProcessGroupAtDeadline(t *testing.T) {
	if os.Getenv("HUNTER_VALIDATOR_TEST_HELPER") == "sleep" {
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	execution := (OSRunner{}).Run(ctx, Invocation{
		Path: os.Args[0],
		Args: []string{"-test.run=TestOSRunnerKillsTheProcessGroupAtDeadline"},
		Env:  append(os.Environ(), "HUNTER_VALIDATOR_TEST_HELPER=sleep"),
	})
	if !execution.TimedOut || !errors.Is(execution.Err, context.DeadlineExceeded) {
		t.Fatalf("execution=%+v", execution)
	}
}
