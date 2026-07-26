package config

import (
	"errors"
	"net/url"
	"os"
	"strings"
	"syscall"
)

const (
	defaultSecretPath = "/run/secrets/assistant_validator_amqp_password"
	maxSecretBytes    = 16 << 10
	amqpHost          = "rabbitmq:5672"
	amqpVHost         = "hunter-assistant"
)

type Config struct {
	amqpPassword string
}

func Load() (Config, error) {
	return LoadFrom(defaultSecretPath)
}

func LoadFrom(secretPath string) (Config, error) {
	password, err := readSecret(secretPath)
	if err != nil {
		return Config{}, errors.New("validator AMQP credential unavailable")
	}
	return Config{amqpPassword: password}, nil
}

func (config Config) AMQPURL() string {
	return (&url.URL{
		Scheme: "amqp",
		User:   url.UserPassword("hunter-assistant-validator", config.amqpPassword),
		Host:   amqpHost,
		Path:   "/" + amqpVHost,
	}).String()
}

func readSecret(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || !safeSecretMode(path, info.Mode().Perm()) || info.Size() <= 0 || info.Size() > maxSecretBytes {
		return "", errors.New("secret file rejected")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("secret file rejected")
	}
	value := strings.TrimSpace(string(body))
	if value == "" || strings.ContainsAny(value, "\x00\r\n\t ") {
		return "", errors.New("secret value rejected")
	}
	return value, nil
}

func safeSecretMode(path string, mode os.FileMode) bool {
	if mode == 0o400 {
		return true
	}
	if mode != 0o600 {
		return false
	}
	// Standalone Compose preserves a file-backed secret's host mode. Permit a
	// 0600 source only when the in-container read-only bind rejects write opens.
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err == nil {
		_ = file.Close()
		return false
	}
	return errors.Is(err, syscall.EROFS) || errors.Is(err, syscall.EACCES)
}
