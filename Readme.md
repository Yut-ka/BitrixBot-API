# Бот‑сборщик диалогов Битрикс24

Python‑приложение для сбора и хранения диалогов из **Открытых линий** Битрикс24. Бот автоматически подключается к новым диалогам, сохраняет их в SQLite и **сразу переводит** разговор оператору.

Это обходное решение ограничения Битрикс24, когда получить диалог нельзя, если в нём не участвует администратор/приложение.

## Особенности

- Работает по **HTTP** (без HTTPS).
- Поддерживает **DuckDNS** *или* **свой домен**.
- **Важно:** URL обработчика в Bitrix24 **должен заканчиваться на** `/python_bot/` (со слэшем).
- Nginx проксирует на Gunicorn со **срезом префикса** (`proxy_pass http://127.0.0.1:8080/;` — обратите внимание на завершающий `/`).

## Архитектура

- `main.py` — Flask‑приложение: вебхуки Б24 + локальный API.
- `config.py` — хранит `CLIENT_ID` / `CLIENT_SECRET` (если используете OAuth).
- `auth.json` — токены после установки приложения (**не коммитить**).
- `dialogs.db` — SQLite‑БД с диалогами/участниками/сообщениями (**не коммитить**).
- `setup.sh` — интерактивная установка сервера и деплой бота.

---

## Установка

### 0) Подготовьте домен
- **Вариант A (DuckDNS):** зарегистрируйтесь на duckdns.org, создайте субдомен и получите токен.
- **Вариант B (свой домен):** создайте **A‑запись** вида  
  `bot.mydomain.com → <публичный IP вашего VPS>`.

### 1) Залейте проект на сервер
Вариант 1: распакуйте архив в `/var/www/html/python_bot`.  
Вариант 2: пустая папка — `setup.sh` сам клонирует репозиторий.

### 2) Запустите установщик
```bash
chmod +x setup.sh
sudo ./setup.sh
```
Скрипт:
- установит пакеты (nginx, python3, venv, git, sqlite3 и т.д.),
- создаст venv и поставит зависимости,
- инициализирует БД,
- спросит: **DuckDNS** или **свой домен**,
- настроит Nginx и systemd‑сервис Gunicorn.

### 3) Проверка
Откройте: `http://<ваш-домен>/python_bot/` — должен отвечать бот.  
Если видите **404**, значит забыли слэш или не срезается префикс (см. Nginx ниже).

---

## Частые ошибки и решения

### Nginx не создал пользователя www-data
```bash
sudo groupadd --system www-data
sudo useradd --system --gid www-data --shell /usr/sbin/nologin --home /var/www www-data
sudo chown -R www-data:www-data /var/www/html/python_bot
```
Повторно запустите установщик.

### Ошибка venv «ensurepip is not available»
```bash
sudo apt install -y python3-venv
```
(ставьте пакет под вашу версию Python). Повторите установку.

### Совсем «чистый» сервер (нет `/var/www`)
```bash
sudo apt update
sudo apt install -y nginx unzip
sudo mkdir -p /var/www/html
```
Далее — к шагу «Залейте проект».

### Файрвол
Если включён UFW:
```bash
sudo ufw allow 80/tcp
```

---

## Настройка приложения в Битрикс24

1) **Создайте локальное приложение**  
**Приложения → Разработчикам → Добавить приложение → Другое → Локальное приложение**.

2) **Укажите пути**  
- **Путь обработчика:** `http://<ваш-домен>/python_bot/`  ← **обязательно со слэшем /**  
- **Путь для первоначальной установки:** тот же URL.

3) **Права (scopes)** — критично:
- `imbot` — регистрация чат‑бота и обработка событий,
- `imopenlines` — работа с открытыми линиями,
- `user` — данные пользователей (имена и т.д.).

4) **Добавьте бота** «Python Interceptor Bot» в нужную открытую линию (Контакт‑центр → Открытые линии).

5) **Файлы:**
- БД: `/var/www/html/python_bot/dialogs.db`
- Токены: `/var/www/html/python_bot/auth.json` (появится после установки приложения)

6) **Переустановка**  
Меняли набор прав? → **удалите и установите приложение заново**.  
Если после установки **не появился** `auth.json`, убедитесь, что URL обработчика **со слэшем**, удалите старый `auth.json` (если был) и переустановите приложение.  
В крайнем случае смените `API_SECRET_TOKEN` в `main.py` и перезапустите сервис.

---

## Конфиг Nginx (ключевой фрагмент)

Обратите внимание на два момента: редирект для пути без слэша и **слэш в конце `proxy_pass`** — он срезает префикс `/python_bot/` перед передачей на Flask.

```nginx
server {
    listen 80;
    server_name your-domain.tld;
    root /var/www/html;
    index index.html;

    location = /python_bot { return 301 /python_bot/; }

    location /python_bot/ {
        proxy_pass http://127.0.0.1:8080/;  # ВАЖНО: слэш в конце!
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 300;
        proxy_send_timeout 300;
        proxy_redirect off;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Применение:
```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## Службы и логи

- **Gunicorn**  
  ```bash
  systemctl status gunicorn
  journalctl -u gunicorn -n 200 --no-pager
  ```
- **Логи приложения**  
  ```bash
  tail -f /var/www/html/python_bot/bot.log
  ```
- **Доступность Flask напрямую**  
  ```bash
  curl -i http://127.0.0.1:8080/
  ```
