#!/usr/bin/env bash
set -euo pipefail

# Install the reviewed release directly; never execute an unpinned bootstrap script.
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
  echo 'This installer supports Linux x86_64 only.' >&2
  exit 1
}
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
url='https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_linux_amd64.tar.gz'
expected='cf7e688ed0c4c48adffca788b496076e31060b67ac5afe1e43dbb5499c20c88b'
curl -fsSL --retry 3 --connect-timeout 20 -o "$archive" "$url"
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
mkdir -p "$HOME/.foundry/bin"
tar -xzf "$archive" -C "$HOME/.foundry/bin" forge cast anvil chisel
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$HOME/.foundry/bin" >> "$GITHUB_PATH"
fi
"$HOME/.foundry/bin/forge" --version
