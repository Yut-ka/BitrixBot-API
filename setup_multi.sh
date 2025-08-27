#!/usr/bin/env bash
set -o pipefail

# ==============================================================================
#  Multi-instance setup for Bitrix24 Dialog Collector Bot (HTTP only)
#  - Multiple instances per server (different Bitrix accounts)
#  - Each instance has its own dir, venv, DB, auth.json, service and Nginx prefix
#  - Supports DuckDNS or your own domain (IDN domains supported via idn2)
#  - Adds a simple botctl helper to start/stop/status instances
# ==============================================================================

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_BLUE='\033[0;34m'; C_YELLOW='\033[0;33m'
info(){ echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
success(){ echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
error(){ echo -e "${C_RED}[ERROR]${C_RESET} $1"; exit 1; }
warn(){ echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }

if [ "$EUID" -ne 0 ]; then error "Запустите скрипт с sudo (sudo ./setup_multi.sh)"; fi

# ---------- Packages ----------
info "Installing packages..."
apt-get update -y || error "apt update"
apt-get install -y nginx python3 python3-venv python3-pip git sqlite3 curl cron || error "apt install"

# ---------- Instance basics ----------
read -r -p "Укажите ИМЯ инстанса (только [a-z0-9-]), напр. client1: " INSTANCE
INSTANCE=$(printf '%s' "$INSTANCE" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
if ! printf '%s' "$INSTANCE" | grep -Eq '^[a-z0-9-]+$'; then
  error "Некорректное имя инстанса: допустимы только строчные латинские буквы, цифры и дефис"
fi

BASE_DIR="/var/www/b24bots"
PROJECT_DIR="${BASE_DIR}/${INSTANCE}"
REPO_URL_DEFAULT="https://github.com/Yut-ka/BitrixBot-API"

mkdir -p "$BASE_DIR"

# ---------- Domain choice ----------
echo "Выберите вариант домена:"
echo "  1) DuckDNS (*.duckdns.org)"
echo "  2) Свой домен (например, bot.example.com)"
read -r -p "Ваш выбор (1/2): " DOMAIN_CHOICE

if [ "$DOMAIN_CHOICE" = "1" ]; then
  read -r -p "DuckDNS субдомен (my-bot): " DUCKDNS_SUB
  read -r -p "DuckDNS token: " DUCKDNS_TOKEN
  [ -z "$DUCKDNS_SUB" ] && error "Пустой субдомен"
  [ -z "$DUCKDNS_TOKEN" ] && error "Пустой токен"
  DOMAIN_FQDN="${DUCKDNS_SUB}.duckdns.org"
  DUCKDNS_SCRIPT_PATH="/etc/duckdns"
  mkdir -p "$DUCKDNS_SCRIPT_PATH"
  echo "echo url=\"https://www.duckdns.org/update?domains=${DUCKDNS_SUB}&token=${DUCKDNS_TOKEN}&ip=\" | curl -k -o ${DUCKDNS_SCRIPT_PATH}/${DUCKDNS_SUB}.log -K -" > "${DUCKDNS_SCRIPT_PATH}/${DUCKDNS_SUB}.sh"
  chmod 700 "${DUCKDNS_SCRIPT_PATH}/${DUCKDNS_SUB}.sh"
  (crontab -l 2>/dev/null; echo "*/5 * * * * ${DUCKDNS_SCRIPT_PATH}/${DUCKDNS_SUB}.sh >/dev/null 2>&1") | crontab -
  bash "${DUCKDNS_SCRIPT_PATH}/${DUCKDNS_SUB}.sh"
elif [ "$DOMAIN_CHOICE" = "2" ]; then
  read -r -p "Ваш домен (FQDN), например: бот.мойдомен.рф или bot.example.com: " DOMAIN_FQDN
  [ -z "$DOMAIN_FQDN" ] && error "Пустой домен"
  # IDN → Punycode, если есть не-ASCII символы
  if printf '%s' "$DOMAIN_FQDN" | grep -qP '[^\x00-\x7F]'; then
    info "Обнаружен IDN домен, выполняю конвертацию в Punycode..."
    if ! command -v idn2 >/dev/null 2>&1; then
      apt-get install -y idn2 || warn "Не удалось установить idn2, продолжаю без конвертации"
    fi
    if command -v idn2 >/dev/null 2>&1; then
      DOMAIN_ASCII="$(idn2 "$DOMAIN_FQDN" 2>/dev/null || true)"
      if [ -n "$DOMAIN_ASCII" ]; then
        warn "IDN: ${DOMAIN_FQDN} -> ${DOMAIN_ASCII}"
        DOMAIN_FQDN="$DOMAIN_ASCII"
      else
        warn "Не удалось сконвертировать IDN домен, использую исходный: ${DOMAIN_FQDN}"
      fi
    fi
  fi
  warn "Проверьте, что A-запись домена указывает на IP этого сервера."
else
  error "Неизвестный выбор"
fi

# ---------- Port assignment per instance ----------
PORTS_MAP="/etc/b24bot/ports.map"
mkdir -p /etc/b24bot

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | grep -q ":${p} "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpn 2>/dev/null | grep -q ":${p} "
  else
    # грубая проверка через bash/tcp
    (echo >/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1 && return 0 || return 1
  fi
}

if grep -q "^${INSTANCE}:" "$PORTS_MAP" 2>/dev/null; then
  APP_PORT="$(grep "^${INSTANCE}:" "$PORTS_MAP" | head -n1 | cut -d: -f2)"
else
  APP_PORT=""
  for p in $(seq 18080 18180); do
    if ! port_in_use "$p"; then APP_PORT="$p"; break; fi
  done
  [ -z "$APP_PORT" ] && error "Нет свободного порта в диапазоне 18080..18180"
  echo "${INSTANCE}:${APP_PORT}" >> "$PORTS_MAP"
fi
info "Инстанс ${INSTANCE} будет слушать 127.0.0.1:${APP_PORT}"

# ---------- Get sources ----------
if [ -d "$PROJECT_DIR/.git" ] || [ -f "$PROJECT_DIR/main.py" ]; then
  warn "Каталог ${PROJECT_DIR} уже существует — обновление пропущено"
else
  read -r -p "URL репозитория (Enter = по умолчанию): " REPO_URL
  REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
  git clone "$REPO_URL" "$PROJECT_DIR" || error "git clone"
fi

# ---------- Python venv (без source) ----------
cd "$PROJECT_DIR" || error "cd project"
python3 -m venv .venv || error "venv"
PIP="${PROJECT_DIR}/.venv/bin/pip"
PY="${PROJECT_DIR}/.venv/bin/python"
GUNICORN="${PROJECT_DIR}/.venv/bin/gunicorn"

"$PIP" install --upgrade pip || error "pip upgrade"
if [ -f requirements.txt ]; then
  "$PIP" install -r requirements.txt || error "pip install -r requirements.txt"
else
  warn "Нет requirements.txt — пропускаю установку зависимостей"
fi


# ---------- Per-instance API secret ----------
read -r -p "API секрет-токен для админ-эндпойнтов (Enter = сгенерировать): " API_TOKEN
API_TOKEN=$(printf '%s' "${API_TOKEN:-}" | tr -d '\r')
if [ -z "$API_TOKEN" ]; then
  API_TOKEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
  info "Сгенерирован API_SECRET_TOKEN: $API_TOKEN"
fi

ENV_DIR="/etc/b24bot/env"
mkdir -p "$ENV_DIR"
ENV_FILE="${ENV_DIR}/${INSTANCE}.env"
# Значение алфанумерик — можно без кавычек
echo "API_SECRET_TOKEN=$API_TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
info "API_SECRET_TOKEN сохранён в $ENV_FILE"


# ---------- Ownership & DB init ----------
chown -R www-data:www-data "$PROJECT_DIR"
sudo -u www-data "$PY" - <<PYCODE || error "init_db failed"
import sys, os
sys.path.append("$PROJECT_DIR")
try:
    import main
    if hasattr(main, "init_db"):
        main.init_db()
        print("DB init done")
    else:
        print("main.init_db() не найден — пропуск")
except Exception as e:
    print("DB init error:", e)
    raise
PYCODE

# ---------- Systemd service (unique per instance) ----------
SERVICE="gunicorn-b24bot-${INSTANCE}.service"
cat > "/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=Gunicorn Bitrix24 Bot (${INSTANCE})
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PROJECT_DIR}
ExecStart=${GUNICORN} --workers 3 --bind 127.0.0.1:${APP_PORT} main:app
Restart=always
Environment="PATH=${PROJECT_DIR}/.venv/bin"
EnvironmentFile=/etc/b24bot/env/${INSTANCE}.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE}"

# ---------- Nginx per-domain vhost + per-instance snippets ----------

# --- уборка старых конфигов, которые могли держать default_server ---
# старый единичный конфиг
if [ -f /etc/nginx/sites-available/b24bots ]; then
  rm -f /etc/nginx/sites-enabled/b24bots
  rm -f /etc/nginx/sites-available/b24bots
fi

# опционально отключаем стандартный default (иначе оставь как есть)
if [ -L /etc/nginx/sites-enabled/default ]; then
  unlink /etc/nginx/sites-enabled/default
fi

# Для каждого домена свой vhost и своя папка сниппетов
SITE="/etc/nginx/sites-available/b24bots-${DOMAIN_FQDN}"
ENABLED="/etc/nginx/sites-enabled/b24bots-${DOMAIN_FQDN}"
SNIPPETS_DIR="/etc/nginx/b24bots.d/${DOMAIN_FQDN}"
mkdir -p "$SNIPPETS_DIR"

if [ ! -f "$SITE" ]; then
cat > "$SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_FQDN};
    root /var/www/html;
    index index.html;

    include ${SNIPPETS_DIR}/*.conf;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sf "$SITE" "$ENABLED"
fi

SNIPPET="${SNIPPETS_DIR}/${INSTANCE}.conf"
cat > "$SNIPPET" <<EOF
# Instance: ${INSTANCE}
location = /${INSTANCE}            { return 301 /${INSTANCE}/; }
location = /${INSTANCE}/python_bot { return 301 /${INSTANCE}/python_bot/; }

location /${INSTANCE}/python_bot/ {
    proxy_pass http://127.0.0.1:${APP_PORT}/python_bot/;  # проксируем на такой же путь
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Prefix "/${INSTANCE}";
    proxy_read_timeout 300;
    proxy_send_timeout 300;
    proxy_redirect off;
}

location /${INSTANCE}/api/ {
    proxy_pass http://127.0.0.1:${APP_PORT}/api/;        # и API на /api/
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Prefix "/${INSTANCE}";
    proxy_read_timeout 300;
    proxy_send_timeout 300;
    proxy_redirect off;
}
EOF

nginx -t || error "nginx -t failed"
systemctl reload nginx

# ---------- botctl helper ----------
cat > /usr/local/bin/botctl <<'CTL'
#!/usr/bin/env bash
set -e
if [ "$EUID" -ne 0 ]; then echo "Use sudo"; exit 1; fi
usage(){ echo "Usage: botctl <instance> {on|off|restart|status|enable|disable|purge}"; exit 1; }
[ -z "${1:-}" ] && usage
[ -z "${2:-}" ] && usage

INSTANCE="$1"; CMD="$2"
SERVICE="gunicorn-b24bot-${INSTANCE}.service"
PROJECT_DIR="/var/www/b24bots/${INSTANCE}"
ENABLED_FLAG="${PROJECT_DIR}/ENABLED"
DISABLED_FLAG="${PROJECT_DIR}/DISABLED"
PORTS_MAP="/etc/b24bot/ports.map"
ENV_FILE="/etc/b24bot/env/${INSTANCE}.env"

case "$CMD" in
  on)
    rm -f "$DISABLED_FLAG"; touch "$ENABLED_FLAG"
    systemctl start "$SERVICE"
    echo "Instance ${INSTANCE}: ON"
    ;;
  off)
    systemctl stop "$SERVICE" || true
    rm -f "$ENABLED_FLAG"; touch "$DISABLED_FLAG"
    echo "Instance ${INSTANCE}: OFF"
    ;;
  restart)
    systemctl restart "$SERVICE"
    ;;
  status)
    systemctl status --no-pager "$SERVICE" || true
    if [ -f "$DISABLED_FLAG" ]; then echo "Runtime enabled: no"; else echo "Runtime enabled: yes"; fi
    ;;
  enable)
    systemctl enable "$SERVICE"
    ;;
  disable)
    systemctl disable "$SERVICE"
    ;;
  purge)
    echo "Purging instance ${INSTANCE}..."

    # 1) stop & remove service
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}"
    systemctl daemon-reload

    # 2) delete project dir
    rm -rf "$PROJECT_DIR"

    # 3) remove port reservation
    if [ -f "$PORTS_MAP" ]; then
      sed -i "/^${INSTANCE}:/d" "$PORTS_MAP"
    fi

    # 4) remove per-instance env file
    rm -f "$ENV_FILE"

    # 5) remove nginx snippets for this instance under ALL domains
    CHANGED_NGINX=0
    for SNIPPET in /etc/nginx/b24bots.d/*/${INSTANCE}.conf; do
      [ -e "$SNIPPET" ] || continue
      DIR="$(dirname "$SNIPPET")"
      DOMAIN_ASCII="$(basename "$DIR")"
      rm -f "$SNIPPET"
      if [ -z "$(ls -A "$DIR" 2>/dev/null)" ]; then
        SITE="/etc/nginx/sites-available/b24bots-${DOMAIN_ASCII}"
        LINK="/etc/nginx/sites-enabled/b24bots-${DOMAIN_ASCII}"
        rm -f "$LINK" "$SITE"
        rmdir "$DIR" 2>/dev/null || true
      fi
      CHANGED_NGINX=1
      echo "Removed nginx snippet for domain ${DOMAIN_ASCII}"
    done

    if [ "$CHANGED_NGINX" -eq 1 ]; then
      nginx -t && systemctl reload nginx
    fi

    echo "Instance ${INSTANCE} purged."
    ;;
  *)
    usage
    ;;
esac
CTL
chmod +x /usr/local/bin/botctl

success "Готово!"
echo
echo "Домен:   http://${DOMAIN_FQDN}/${INSTANCE}/python_bot/"
echo "Сервис:  systemctl status gunicorn-b24bot-${INSTANCE}"
echo "Управление: sudo botctl ${INSTANCE} {on|off|restart|status|enable|disable|purge}"
