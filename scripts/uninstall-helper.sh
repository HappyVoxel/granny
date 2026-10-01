#!/usr/bin/env bash
# Removes the root helper and its sudoers entry.
# Blocking stops working until scripts/install-helper.sh runs again.
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "run me with sudo: sudo $0" >&2
  exit 1
fi

rm -f /etc/sudoers.d/granny
rm -rf /usr/local/libexec/granny
echo "helper and sudoers entry removed."
