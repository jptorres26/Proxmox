#!/usr/bin/env bash
# shellcheck disable=SC2016 # the bash -c bodies expand in the child shell.
set -euo pipefail

# UU_SEND_MAIL: notifications go through sendmail with explicit headers.
# `mail -a 'Header: value'` only works with bsd-mailx; with GNU mailutils or
# s-nail `-a` attaches a file, the call failed, and `|| true` hid it.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/sendmail" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$WORK_DIR/sendmail.args"
cat > "$WORK_DIR/sendmail.message"
STUB
cat > "$WORK_DIR/bin/mail" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$WORK_DIR/mail.args"
cat > /dev/null
STUB
chmod +x "$WORK_DIR/sendmail" "$WORK_DIR/bin/mail"

send() {  # send <sendmail path> <to> <from> <subject>
  printf 'Body line\n' | UU_SENDMAIL="$1" PATH="$WORK_DIR/bin:$PATH" bash -c '
    source "$1/status-model.sh"
    UU_SEND_MAIL "$2" "$3" "$4"' _ "$ROOT_DIR" "$2" "$3" "$4"
}

send "$WORK_DIR/sendmail" 'ops@example.org, admin@example.org' 'Updater <updater@example.org>' 'Ultimate Updater summary - pve1'
[[ "$(cat "$WORK_DIR/sendmail.args")" == '-oi -f updater@example.org -- ops@example.org admin@example.org' ]]
grep -Fxq 'From: Updater <updater@example.org>' "$WORK_DIR/sendmail.message"
grep -Fxq 'To: ops@example.org admin@example.org' "$WORK_DIR/sendmail.message"
grep -Fxq 'Subject: Ultimate Updater summary - pve1' "$WORK_DIR/sendmail.message"
grep -Fxq 'Content-Type: text/plain; charset=UTF-8' "$WORK_DIR/sendmail.message"
grep -Fxq 'Body line' "$WORK_DIR/sendmail.message"

# Without sendmail, mail(1) gets no header "attachments" and ends its options.
send "$WORK_DIR/missing" root root 'Ultimate Updater'
[[ "$(cat "$WORK_DIR/mail.args")" == '-s Ultimate Updater -r root -- root' ]]

# Recipients and senders that would be read as options are refused.
for arguments in '-oQ/tmp root' 'root -oQ/tmp' 'a"b root'; do
  read -r to from <<< "$arguments"
  if send "$WORK_DIR/sendmail" "$to" "$from" subject 2>/dev/null; then
    echo "accepted mail addresses: $arguments" >&2
    exit 1
  fi
done

# No caller uses the bsd-mailx-only header syntax anymore.
if grep -n "mail -a 'Content-Type" "$ROOT_DIR"/update.sh "$ROOT_DIR"/check-updates.sh "$ROOT_DIR"/status-model.sh; then
  exit 1
fi
# USER is unset in systemd units: the default sender is the literal $USER,
# which STATUS_MODEL_EXPAND_SENDER resolves.
grep -Fq 'email_sender="${email_sender:-\$USER}"' "$ROOT_DIR/status-model.sh"

echo 'mail delivery: PASS'
