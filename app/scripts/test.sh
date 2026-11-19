#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DATABASE_URL="file:$tmp/test.db"
./node_modules/.bin/prisma db push --skip-generate >/dev/null
./node_modules/.bin/vitest run
