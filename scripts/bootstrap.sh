#!/usr/bin/env bash
# Prepare runtime folders and secrets on the lab VPS. Idempotent: safe to re-run.
#  - creates .env (chmod 600) from .env.example, filling every empty value with a random secret
#    (existing values are kept)
#  - builds the Mosquitto password file, ACL and healthcheck options (owner 1883:1883, mode 0600)
#  - writes the operator's mosquitto_sub options file to ~/.config/aibox/mqtt-operator.conf (0600)
# Secrets never appear in argv, shell history or output: they travel through files and stdin only.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
MOSQ_IMG='eclipse-mosquitto:2.1.2-alpine@sha256:6f8d8a947c506f8a2290ec65cd4bd2bc7cb4d43fb5f6271f861cb013e2ef9797'
MQ="$ROOT/mosquitto"

echo "[1/4] Runtime folders"
mkdir -p "$ROOT/frigate/storage" "$ROOT/test-media"
sudo install -d -m 0750 -o 1883 -g 1883 "$MQ/data" "$MQ/log"

echo "[2/4] .env (random values for empty keys, existing values kept)"
if [[ ! -f "$ROOT/.env" ]]; then
  (umask 077 && cp "$ROOT/.env.example" "$ROOT/.env")
fi
chmod 600 "$ROOT/.env"
python3 - "$ROOT/.env" <<'PY'
import re, secrets, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out, filled = [], 0
for line in lines:
    m = re.fullmatch(r"([A-Z0-9_]+)=(.*)", line)
    if m and m.group(2) == "":
        line = f"{m.group(1)}={secrets.token_hex(24)}"
        filled += 1
    out.append(line)
open(path, "w").write("\n".join(out) + "\n")
print(f"      filled {filled} empty secret(s)")
PY

# Read a value from .env without sourcing it (no eval of file content).
env_get() { grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2-; }

echo "[3/4] Mosquitto password file, ACL, healthcheck options"
# Private scratch dir owned by the broker uid, so only root and uid 1883 can read the hashes.
tmp="$(sudo mktemp -d)"
trap 'sudo rm -rf "$tmp"' EXIT
sudo chown 1883:1883 "$tmp"
sudo chmod 0700 "$tmp"
sudo install -m 0600 -o 1883 -g 1883 /dev/null "$tmp/passwd"
# Mosquitto 2.1: "mosquitto_passwd -c" refuses existing files, so add users to an empty file instead.
add_user() {  # add_user <mqtt-user> <env-key>; the password goes through stdin only (printf is a builtin)
  local pw
  pw="$(env_get "$2")"
  printf '%s\n%s\n' "$pw" "$pw" | sudo docker run --rm -i --network none --user 1883:1883 \
    -v "$tmp:/work" "$MOSQ_IMG" mosquitto_passwd /work/passwd "$1" >/dev/null
}
add_user frigate FRIGATE_MQTT_PASSWORD
add_user insights MQTT_INSIGHTS_PASSWORD
add_user operator MQTT_OPERATOR_PASSWORD
add_user healthcheck MQTT_HEALTHCHECK_PASSWORD

write_1883() {  # write_1883 <dest>: stdin -> file owned 1883:1883, mode 0600
  sudo sh -c 'umask 077 && cat > "$1" && chown 1883:1883 "$1"' _ "$1"
}
sudo install -m 0600 -o 1883 -g 1883 "$tmp/passwd" "$MQ/config/passwd"
write_1883 "$MQ/config/acl" < "$MQ/acl.template"
printf -- '-u healthcheck\n-P %s\n' "$(env_get MQTT_HEALTHCHECK_PASSWORD)" | write_1883 "$MQ/config/healthcheck.conf"

mkdir -p "$HOME/.config/aibox"
chmod 700 "$HOME/.config/aibox"
(umask 077 && printf -- '-u operator\n-P %s\n' "$(env_get MQTT_OPERATOR_PASSWORD)" \
  > "$HOME/.config/aibox/mqtt-operator.conf")

# If the broker is already running, reload users/ACL (SIGHUP).
if sudo docker compose ps --status running --services 2>/dev/null | grep -qx mosquitto; then
  sudo docker compose kill -s SIGHUP mosquitto >/dev/null && echo "      mosquitto reloaded"
fi

echo "[4/4] Summary (no secrets printed)"
ls -l "$ROOT/.env"
sudo ls -ln "$MQ/config"
ls -l "$HOME/.config/aibox/mqtt-operator.conf"
echo "Done. Next: scripts/fetch-test-media.sh, then: sudo docker compose up -d"
