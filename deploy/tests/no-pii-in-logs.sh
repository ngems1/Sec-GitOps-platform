#!/usr/bin/env bash
# CI guard (ADR 0011, RUNBOOK "What we never log"): fails if a log call names a personal field.
#
#   deploy/tests/no-pii-in-logs.sh [dir...]   default: src terraform-aws/lambda
#
# It looks at single lines that call a logger (Go logrus, Python logging and our info()/warn()
# helpers, pino, console, .NET Console.WriteLine and CartLog, Log4j) and fails when such a line also names:
# an email, the user or session ID (the cart's userId is the session ID), card fields, the
# address, the client IP, the user agent, the query string, the whole request, or the
# assistant's question/answer. Trailing comments are ignored.
#
# Obvious patterns only: a field added on another line (a multi-line Fields map or extra dict)
# is not seen. The per-service tests cover the real log lines. A line that is fine despite a
# match ends with a "pii-ok" comment saying why.
set -euo pipefail

cd "$(dirname "$0")/../.."
dirs=("$@")
[ ${#dirs[@]} -gt 0 ] || dirs=(src terraform-aws/lambda)

LOG_CALL='(\b(log|logger|olog|lh\.log)\.(With[A-Za-z]*|Info[a-z]*|Warn[a-z]*|Error[a-z]*|Debug[a-z]*|Print[a-z]*|Fatal[a-z]*|info|warning|warn|error|debug|exception|critical)\(|\bconsole\.(log|info|warn|error|debug)\(|\bConsole\.Write(Line)?\(|\bCartLog\.(Info|Warn|Error)\(|(^|[^.A-Za-z_])(info|warn)\()'
PERSONAL='(\.Email\b|\.email\b|\bemail=|["'"'"']email["'"'"']|\bUserId\b|\buser_id\b|\buserId\b|["'"'"']session["'"'"']|\bsessionID\b|\bsession_id\b|X-Session-Id|hashedSession|credit_card|CreditCard|cardNumber|card_number|\bcvv\b|\.Address\b|street_address|StreetAddress|zip_code|ZipCode|RemoteAddr|client_address|UserAgent|User-Agent|X-Forwarded-For|RawQuery|URL\.Query|JSON\.stringify\(call\.request|question\)|question,|\{question|question\}|\+ ?question|\.question\b|\[["'"'"']question["'"'"']\]|answer\)|\{answer|\.Answer\b|\[["'"'"']answer["'"'"']\])'

hits=$(grep -rnE "$LOG_CALL" "${dirs[@]}" \
         --include='*.go' --include='*.py' --include='*.js' --include='*.cs' --include='*.java' \
         --exclude='*_test.go' --exclude='test_*.py' --exclude='*.test.js' --exclude='*Tests.cs' \
         --exclude='demo_pb2*.py' --exclude-dir=node_modules --exclude-dir=genproto \
         --exclude-dir=tests --exclude-dir=bin --exclude-dir=obj 2>/dev/null \
       | grep -v 'pii-ok' \
       | sed -E 's@[[:space:]]+//.*$@@; s@[[:space:]]+#[[:space:]].*$@@' \
       | grep -E "$PERSONAL" || true)

if [ -n "$hits" ]; then
  echo "Log calls that name personal data (ADR 0011, RUNBOOK 'What we never log'):"
  echo "$hits"
  echo "Log the order ID (or nothing) instead. If a line is fine, end it with a 'pii-ok' comment saying why."
  exit 1
fi
echo "No personal data in log calls (${dirs[*]})."
