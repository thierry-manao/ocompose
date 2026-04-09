#!/usr/bin/env bash
set -e

# Start SSH daemon (requires root via sudo)
sudo /usr/sbin/sshd

# Execute the CMD (default: /bin/bash)
exec "$@"
