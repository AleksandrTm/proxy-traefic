#!/bin/bash
set -e

# ---------------- базовые файлы ----------------
STATE_FILE="/tmp/hosts-watcher-cache.json"
HOSTS_FILE="/etc/hosts"
START_MARKER="# dynamic"
END_MARKER=""

# ---------------- TLS-конфигурация ----------------
CERTS_DIR="/certs"               # монтируется из хоста   («./certs:/certs»)
DYNA_YML="/app/dynamic.yml"      # монтируется из хоста   («./dynamic.yml:/app/dynamic.yml»)
CERT_RENEW_DAYS=30               # заново выпускать, если осталось < 30 дней

secs_in_day=$((60*60*24))

mkdir -p "$CERTS_DIR"
[[ -f "$STATE_FILE" ]] || echo "{}" > "$STATE_FILE"
[[ -f "$DYNA_YML"   ]] || echo -e "tls:\n  certificates:\n" > "$DYNA_YML"

# ---------- функции ----------
generate_cert() {
  local dom="$1"
  local crt="$CERTS_DIR/${dom}.crt"
  local key="$CERTS_DIR/${dom}.key"
  local renew_before=$((CERT_RENEW_DAYS*secs_in_day))

  local need_gen=0
  if [[ ! -f "$crt" || ! -f "$key" ]]; then
    need_gen=1
  elif ! openssl x509 -checkend "$renew_before" -noout -in "$crt" 2>/dev/null; then
    echo "⏰  $dom: сертификат истекает менее чем через $CERT_RENEW_DAYS дней – обновляем"
    need_gen=1
  fi

  if [[ "$need_gen" -eq 1 ]]; then
    echo "🔐  Генерируем сертификат для $dom"
    mkcert -cert-file "$crt" -key-file "$key" "$dom"
    # 🔗  ДОБАВЛЯЕМ ROOT CA В ЦЕПОЧКУ
    CAROOT=$(mkcert -CAROOT)            # путь к каталогу CA
    ROOTCA="$CAROOT/rootCA.pem"
    # если root уже не приклеен – приклеиваем
    if ! grep -q "BEGIN CERTIFICATE" -A1 "$crt" | grep -q "mkcert development CA"; then
      cat "$ROOTCA" >> "$crt"
      echo "➕  Root CA добавлен в $crt"
    fi
    chmod 640 "$crt" "$key"
  else
    echo "✅  Сертификат для $dom актуален"
  fi
}

update_dynamic_yml() {
  local crt="$1"
  local key="$2"
  if ! grep -qF "$crt" "$DYNA_YML"; then
    printf "    - certFile: %s\n      keyFile:  %s\n" "$crt" "$key" >> "$DYNA_YML"
    echo "📄  Добавили запись о сертификате в dynamic.yml"
  fi
}

echo "🚀 Watcher запущен. Слушаем docker events..."

docker events --filter event=start --filter event=stop --format '{{json .}}' |
while read event; do
  CID=$(echo "$event" | jq -r '.id')
  ACT=$(echo "$event" | jq -r '.Action')
  NAME=$(echo "$event" | jq -r '.Actor.Attributes.name')
  SHORT=${CID:0:12}

  echo "📡 Событие: $ACT | Контейнер: $NAME ($SHORT)"

  # ---------- STOP: удаляем домен ----------
  if [[ "$ACT" == "stop" ]]; then
    DOM=$(jq -r --arg id "$CID" '.[$id] // empty' "$STATE_FILE")
    if [[ -z "$DOM" ]]; then
      echo "⚠️  Нет домена в кэше, пропускаем"
      continue
    fi

    echo "🧹 Удаляем $DOM из hosts"
    tmp=$(mktemp)
    sed "/^127\\.0\\.0\\.1 $DOM\$/d" "$HOSTS_FILE" > "$tmp"
    cat "$tmp" | tee "$HOSTS_FILE" > /dev/null && rm "$tmp"
    jq --arg id "$CID" 'del(.[$id])' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    continue
  fi

  # ---------- START: добавляем домен ----------
  LABELS=$(docker inspect "$CID" 2>/dev/null | jq '.[0].Config.Labels' 2>/dev/null) || continue
  [[ "$LABELS" == "null" ]] && continue
  [[ $(echo "$LABELS" | jq -r '."traefik.enable"') != "true" ]] && continue

  DOM=$(echo "$LABELS" | \
        jq -r 'to_entries[] | select(.key|test("traefik\\.http\\.routers\\..*\\.rule")) | .value' | \
        sed -nE "s/Host\(['\`]([^'\`]+)['\`]\)/\1/p")
  if [[ -z "$DOM" ]]; then
    echo "⚠️  Домен не найден"
    continue
  fi

  echo "🟢 Добавляем $DOM в hosts"

  if ! grep -q "$START_MARKER" "$HOSTS_FILE"; then
    tmp=$(mktemp)
    {
      cat "$HOSTS_FILE"
      echo
      echo "$START_MARKER"
      echo "127.0.0.1 $DOM"
      echo "$END_MARKER"
    } > "$tmp"
    cat "$tmp" | tee "$HOSTS_FILE" > /dev/null && rm "$tmp"
  elif ! grep -q "127\\.0\\.0\\.1 $DOM" "$HOSTS_FILE"; then
    tmp=$(mktemp)
    sed "/$END_MARKER/i 127.0.0.1 $DOM" "$HOSTS_FILE" > "$tmp"
    cat "$tmp" | tee "$HOSTS_FILE" > /dev/null && rm "$tmp"
  else
    echo "✅  Домен уже есть"
  fi

  # --- НОВОЕ: TLS ---
  generate_cert "$DOM"
  update_dynamic_yml "$CERTS_DIR/${DOM}.crt" "$CERTS_DIR/${DOM}.key"
  # ------------------

  jq --arg id "$CID" --arg dom "$DOM" '. + {($id): $dom}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
done
