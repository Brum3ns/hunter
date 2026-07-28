#!/bin/sh
set -eu

exec python -m hunter_ansible.main "$@"
