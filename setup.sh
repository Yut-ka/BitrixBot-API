#!/bin/bash

# ==============================================================================
#  Установочный скрипт для Bitrix24 Dialog Collector Bot
# ==============================================================================
#
# Этот скрипт автоматизирует полную настройку сервера для работы бота.
#
# Что он делает:
# 1. Проверяет права суперпользователя.
# 2. Устанавливает необходимое ПО (Nginx, Python, pip, venv, git, sqlite3, curl, cron).
# 3. Клонирует проект, создаёт и активирует venv, ставит зависимости.
# 4. Инициализирует БД от имени www-data.
# 5. Настраивает DuckDNS ИЛИ ваш собственный домен.
# 6. Настраивает Nginx в качестве обратного прокси.
# 7. Создаёт и включает systemd-сервис Gunicorn.
#
# ==============================================================================

set -o pipefail

# --- Цвета для вывода ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[0;33m'

# --- Функции для вывода сообщений ---
info() {
    echo -e "${C_BLUE}[INFO]${C_RESET} $1"
}

success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"
}

error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1"
    exit 1
}

warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"
}

# --- Проверка прав ---
if [ "$EUID" -ne 0 ]; then
    error "Пожалуйста, запустите этот скрипт с правами суперпользователя (через sudo)."
fi

# --- Установка зависимостей ---
info "Обновление списка пакетов..."
apt-get update -y || error "Не удалось обновить список пакетов."

info "Установка необходимого ПО (nginx, python3, python3-pip, python3-venv, git, sqlite3, curl, cron)..."
apt-get install -y nginx python3 python3-pip python3-venv git sqlite3 curl cron || error "Не удалось установить все необходимые пакеты."

# --- Настройка проекта ---
PROJECT_DIR="/var/www/html/python_bot"
REPO_URL="git@github.com:Nikolay1221/bitrix24-dialog-collector.git"

info "Клонирование/обновление репозитория из $REPO_URL..."
if [ -d "$PROJECT_DIR/.git" ]; then
    warn "Директория $PROJECT_DIR уже содержит репозиторий. Обновляю..."
    git -C "$PROJECT_DIR" fetch --all && git -C "$PROJECT_DIR" pull --ff-only || warn "Не удалось обновить, пропускаю."
elif [ -d "$PROJECT_DIR" ]; then
    warn "Директория $PROJECT_DIR уже существует, но без .git. Пропускаю клонирование."
else
    git clone "$REPO_URL" "$PROJECT_DIR" || error "Не удалось клонировать репозиторий. (Проверьте доступ по SSH-ключу)"
fi

cd "$PROJECT_DIR" || error "Не удалось перейти в директорию проекта $PROJECT_DIR."

info "Создание и активация виртуального окружения..."
python3 -m venv .venv || error "Не удалось создать venv"
# shellcheck disable=SC1091
source .venv/bin/activate || error "Не удалось активировать venv"

info "Установка Python-зависимостей..."
pip install --upgrade pip || error "pip upgrade failed"
if [ -f requirements.txt ]; then
    pip install -r requirements.txt || error "Не удалось установить зависимости Python."
else
    warn "Файл requirements.txt не найден. Пропускаю установку зависимостей."
fi

# --- Права и инициализация БД ---
info "Выдача прав на проект пользователю www-data..."
chown -R www-data:www-data "$PROJECT_DIR"

info "Одноразовая инициализация БД..."
sudo -u www-data "${PROJECT_DIR}/.venv/bin/python" - <<PYCODE || error "Инициализация БД завершилась с ошибкой."
import sys, os
sys.path.append("$PROJECT_DIR")
try:
    import main
    if hasattr(main, "init_db"):
        main.init_db()
        print("DB init done")
    else:
        print("main.init_db() не найден, пропускаю.")
except Exception as e:
    print("DB init error:", e)
    raise
PYCODE

# --- Настройка домена ---
DOMAIN_FQDN=""

info "Настройка доменного имени..."
echo "Выберите вариант домена:"
echo "  1) DuckDNS (*.duckdns.org)"
echo "  2) Свой домен (например, bot.mydomain.com)"
read -r -p "Ваш выбор (1/2): " DOMAIN_CHOICE

if [ "$DOMAIN_CHOICE" = "1" ]; then
    # --- Настройка DuckDNS ---
    info "Настройка DuckDNS..."
    read -r -p "Введите ваш субдомен DuckDNS (например, my-bitrix-bot): " DUCKDNS_DOMAIN
    read -r -p "Введите ваш токен DuckDNS: " DUCKDNS_TOKEN

    if [ -z "$DUCKDNS_DOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
        error "Домен и токен DuckDNS не могут быть пустыми."
    fi

    DOMAIN_FQDN="${DUCKDNS_DOMAIN}.duckdns.org"

    DUCKDNS_SCRIPT_PATH="/etc/duckdns"
    mkdir -p "$DUCKDNS_SCRIPT_PATH"
    echo "echo url=\"https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=\" | curl -k -o ${DUCKDNS_SCRIPT_PATH}/duck.log -K -" > "${DUCKDNS_SCRIPT_PATH}/duck.sh"
    chmod 700 "${DUCKDNS_SCRIPT_PATH}/duck.sh"

    info "Добавление задачи в cron для автообновления IP..."
    (crontab -l 2>/dev/null; echo "*/5 * * * * ${DUCKDNS_SCRIPT_PATH}/duck.sh >/dev/null 2>&1") | crontab -

    info "Первый запуск скрипта DuckDNS..."
    bash "${DUCKDNS_SCRIPT_PATH}/duck.sh"

elif [ "$DOMAIN_CHOICE" = "2" ]; then
    read -r -p "Введите ваш домен (FQDN), например bot.mydomain.com: " DOMAIN_FQDN
    if [ -z "$DOMAIN_FQDN" ]; then
        error "Домен не может быть пустым."
    fi
    warn "Убедитесь, что DNS-запись домена указывает на публичный IP этого сервера."
else
    error "Неизвестный выбор. Перезапустите установку."
fi

# --- Настройка Nginx ---
info "Настройка Nginx..."
NGINX_CONF="/etc/nginx/sites-available/default"

# Создаем бэкап стандартного конфига
if [ -f "${NGINX_CONF}" ]; then
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
fi

# Записываем базовую HTTP-конфигурацию
cat > "$NGINX_CONF" << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name ${DOMAIN_FQDN};
    root /var/www/html;

    index index.html;

    # Статический хостинг на /
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Прокси на Flask/Gunicorn
    location /python_bot/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_send_timeout 300;
        proxy_redirect off;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_send_timeout 300;
        proxy_redirect off;
    }
}
EOF

info "Проверка конфигурации Nginx и перезапуск..."
nginx -t && systemctl restart nginx || error "Ошибка в конфигурации Nginx."

# --- Настройка Gunicorn как сервиса systemd ---
info "Настройка сервиса Gunicorn для автозапуска..."
GUNICORN_SERVICE_FILE="/etc/systemd/system/gunicorn.service"
GUNICORN_PATH="${PROJECT_DIR}/.venv/bin/gunicorn"

cat > "$GUNICORN_SERVICE_FILE" << EOF
[Unit]
Description=Gunicorn instance to serve the Bitrix24 Bot
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PROJECT_DIR}
ExecStart=${GUNICORN_PATH} --workers 3 --bind 127.0.0.1:8080 main:app
Restart=always
Environment="PATH=${PROJECT_DIR}/.venv/bin"

[Install]
WantedBy=multi-user.target
EOF

info "Перезагрузка systemd и запуск сервиса Gunicorn..."
systemctl daemon-reload
systemctl start gunicorn
systemctl enable gunicorn

# --- Финальные шаги ---
success "Установка завершена!"
echo
info "Домен настроен: http://${DOMAIN_FQDN}/python_bot/"
echo
info "Осталось сделать несколько шагов вручную:"
echo "1. В настройках вашего приложения в Битрикс24 укажите URL обработчика:"
echo -e "   ${C_YELLOW}http://${DOMAIN_FQDN}/python_bot/${C_RESET}"
echo
echo "2. Установите/переустановите приложение в Битрикс24."
echo
info "Статус сервиса Gunicorn: ${C_YELLOW}systemctl status gunicorn${C_RESET}"
info "Логи бота: ${C_YELLOW}tail -f ${PROJECT_DIR}/bot.log${C_RESET}"
info "Nginx проверки: ${C_YELLOW}nginx -t && systemctl reload nginx${C_RESET}"
