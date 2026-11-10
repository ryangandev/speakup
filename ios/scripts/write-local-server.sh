#!/bin/zsh
# Writes SpeakUp/Settings/LocalServer.json, the server address and token that builds bundle, so
# the app needs no typing in Settings (BundledServer in AppSettings.swift). The file is ignored by
# git; it holds the server token, so never commit or print it.
#
# Usage: ios/scripts/write-local-server.sh [address]
# The address defaults to this Mac's Tailscale name, https://<name>.<tailnet>.ts.net, which
# `tailscale serve` publishes. The token is SPEAKUP_API_TOKEN from server/.env.
set -euo pipefail
root=${0:A:h:h:h}
out=$root/ios/SpeakUp/Settings/LocalServer.json

token=$(sed -n 's/^SPEAKUP_API_TOKEN=//p' "$root/server/.env" | tail -1)
[[ -n $token ]] || { print -u2 "No SPEAKUP_API_TOKEN in server/.env"; exit 1 }

address=${1:-}
if [[ -z $address ]]; then
  tailscale=$(command -v tailscale || print /Applications/Tailscale.app/Contents/MacOS/Tailscale)
  name=$("$tailscale" status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
  address="https://$name"
fi

SPEAKUP_ADDRESS=$address SPEAKUP_TOKEN=$token python3 -c '
import json, os, sys
json.dump({"address": os.environ["SPEAKUP_ADDRESS"], "token": os.environ["SPEAKUP_TOKEN"]}, sys.stdout)
' > "$out"
chmod 600 "$out"
print "Wrote $out for $address. Rebuild the app to bundle it."
