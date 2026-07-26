package check

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	defaultExecutable = "/usr/bin/ansible-playbook"
	defaultConfig     = "/etc/ansible/ansible.cfg"
	defaultWorkRoot   = "/work"
	defaultTimeout    = 10 * time.Second
	maxOutputBytes    = 32 * 1024
	maxSourceBytes    = 64 * 1024
)

type Invocation struct {
	Path string
	Args []string
	Dir  string
	Env  []string
}

type Execution struct {
	ExitCode  int
	Stdout    []byte
	Stderr    []byte
	Truncated bool
	TimedOut  bool
	Err       error
}

type Runner interface {
	Run(context.Context, Invocation) Execution
}

type Result struct {
	Status string   `json:"status"`
	Codes  []string `json:"codes"`
}

type Checker struct {
	WorkRoot   string
	Executable string
	Config     string
	Timeout    time.Duration
	Runner     Runner
}

func (checker Checker) Check(ctx context.Context, source string) Result {
	if source == "" || len(source) > maxSourceBytes || !utf8.ValidString(source) || bytes.IndexByte([]byte(source), 0) >= 0 {
		return failed("validator_source_rejected")
	}

	root := checker.WorkRoot
	if root == "" {
		root = defaultWorkRoot
	}
	workspace, err := os.MkdirTemp(root, "validation-")
	if err != nil {
		return failed("validator_failed")
	}
	defer os.RemoveAll(workspace)
	if err := os.Chmod(workspace, 0o700); err != nil {
		return failed("validator_failed")
	}

	paths := map[string]string{}
	for _, name := range []string{"home", "local", "remote", "tmp"} {
		path := filepath.Join(workspace, name)
		if err := os.Mkdir(path, 0o700); err != nil {
			return failed("validator_failed")
		}
		paths[name] = path
	}
	playbook := filepath.Join(workspace, "playbook.yml")
	if err := os.WriteFile(playbook, []byte(source), 0o600); err != nil {
		return failed("validator_failed")
	}
	if err := os.Chmod(playbook, 0o600); err != nil {
		return failed("validator_failed")
	}

	executable := checker.Executable
	if executable == "" {
		executable = defaultExecutable
	}
	config := checker.Config
	if config == "" {
		config = defaultConfig
	}
	timeout := checker.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	runner := checker.Runner
	if runner == nil {
		runner = OSRunner{}
	}

	runContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	execution := runner.Run(runContext, Invocation{
		Path: executable,
		Args: []string{"--syntax-check", "--inventory", "localhost,", "playbook.yml"},
		Dir:  workspace,
		Env: []string{
			"ANSIBLE_CONFIG=" + config,
			"HOME=" + paths["home"],
			"ANSIBLE_LOCAL_TEMP=" + paths["local"],
			"ANSIBLE_REMOTE_TEMP=" + paths["remote"],
			"TMPDIR=" + paths["tmp"],
			"PATH=/usr/bin:/bin",
			"LANG=C.UTF-8",
			"LC_ALL=C.UTF-8",
			"ANSIBLE_NOCOLOR=1",
			"PYTHONDONTWRITEBYTECODE=1",
			"PYTHONNOUSERSITE=1",
			"PYTHONSAFEPATH=1",
		},
	})

	switch {
	case execution.TimedOut || errors.Is(runContext.Err(), context.DeadlineExceeded):
		return failed("validator_timeout")
	case execution.Truncated:
		return failed("validator_output_too_large")
	case execution.ExitCode == 0 && execution.Err == nil:
		return Result{Status: "valid", Codes: []string{}}
	case execution.ExitCode > 0:
		return Result{Status: "invalid", Codes: []string{"ansible_syntax_invalid"}}
	default:
		return failed("validator_failed")
	}
}

func failed(code string) Result {
	return Result{Status: "failed", Codes: []string{code}}
}

type OSRunner struct{}

func (OSRunner) Run(ctx context.Context, invocation Invocation) Execution {
	if err := ctx.Err(); err != nil {
		return Execution{ExitCode: -1, TimedOut: true, Err: err}
	}

	stdout := &cappedBuffer{limit: maxOutputBytes}
	stderr := &cappedBuffer{limit: maxOutputBytes}
	command := exec.Command(invocation.Path, invocation.Args...)
	command.Dir = invocation.Dir
	command.Env = invocation.Env
	command.Stdout = stdout
	command.Stderr = stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return Execution{ExitCode: -1, Err: err}
	}

	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()

	var waitErr error
	timedOut := false
	select {
	case waitErr = <-waited:
	case <-ctx.Done():
		timedOut = true
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		waitErr = <-waited
	}

	exitCode := -1
	if command.ProcessState != nil {
		exitCode = command.ProcessState.ExitCode()
	}
	if timedOut {
		waitErr = ctx.Err()
	}
	return Execution{
		ExitCode:  exitCode,
		Stdout:    stdout.Bytes(),
		Stderr:    stderr.Bytes(),
		Truncated: stdout.truncated || stderr.truncated,
		TimedOut:  timedOut,
		Err:       waitErr,
	}
}

type cappedBuffer struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (writer *cappedBuffer) Write(value []byte) (int, error) {
	originalLength := len(value)
	remaining := writer.limit - writer.buffer.Len()
	if remaining <= 0 {
		writer.truncated = writer.truncated || originalLength > 0
		return originalLength, nil
	}
	if len(value) > remaining {
		value = value[:remaining]
		writer.truncated = true
	}
	_, _ = writer.buffer.Write(value)
	return originalLength, nil
}

func (writer *cappedBuffer) Bytes() []byte {
	return append([]byte(nil), writer.buffer.Bytes()...)
}
