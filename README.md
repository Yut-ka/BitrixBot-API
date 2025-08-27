# Bitrix24 Bot-API (мульти-инстанс, HTTP-only)

Python/Flask бот для **Открытых линий** Bitrix24. Перехватывает новые диалоги, сохраняет в SQLite и сразу передаёт оператору. Поддерживает **несколько инстансов** на одном сервере (для разных порталов Б24), работу по **HTTP** (без TLS) и домены **DuckDNS** или **собственные** (включая **кириллические** / IDN).

> Важно: URL обработчика в Bitrix24 **должен заканчиваться на** `/python_bot/` (со слэшем).

---

## Возможности
- 🎛️ **Мульти-инстанс**: каждый инстанс — свой порт, своя папка, своя БД и `auth.json`.
- 🌐 **Домен любой**: DuckDNS или свой FQDN (поддержка IDN → Punycode).
- 🔌 **Nginx reverse-proxy** с префиксом `/<instance>/…`.
- 🧩 **Автосоздание БД**: установщик и `ONAPPINSTALL` создают таблицы, если БД отсутствует.
- 🔐 **Админ-токен** в ENV-файле per-instance: `API_SECRET_TOKEN`.
- 🧰 **Утилита botctl**: `on/off/restart/status/enable/disable/purge`.

---

## Архитектура проекта
```
/var/www/b24bots/<instance>/
  ├─ .venv/                # виртуальное окружение Python
  ├─ main.py               # Flask-приложение (вебхуки + API)
  ├─ dialogs.db            # SQLite база диалогов
  ├─ auth.json             # токены/эндоинты Б24 (создаётся ONAPPINSTALL)
  ├─ bot.log               # логи приложения
  ├─ ENABLED / DISABLED    # флаги включения (опционально)
  └─ …
/etc/b24bot/
  ├─ ports.map             # соответствие <instance>:<port>
  └─ env/<instance>.env    # API_SECRET_TOKEN для инстанса
/etc/nginx/
  ├─ sites-{available,enabled}/b24bots-<domain>   # vhost на домен
  └─ b24bots.d/<domain>/<instance>.conf           # локации инстанса
```

---

## Установка

### 1) Подготовка сервера
```bash
chmod +x setup_multi.sh
sudo ./setup_multi.sh
```
Мастер спросит:
- `instance` — имя в `[a-z0-9-]`, напр. `client1`;
- домен: DuckDNS (субдомен + токен) **или** свой FQDN (IDN поддерживается);
- `API_SECRET_TOKEN` — можно ввести вручную или сгенерировать автоматически.

Итоговый URL:
```
http://<домен>/<instance>/python_bot/
```

### 2) Настройка локального приложения в Bitrix24
1. **Приложения → Разработчикам → Добавить → Другое → Локальное приложение**.  
2. **Пути** (оба одинаковые):  
   `http://<домен>/<instance>/python_bot/`  **(со слэшем!)**
3. **Права** (scopes): `imbot`, `imopenlines`, `user`.
4. Установите приложение — в логах появится `ONAPPINSTALL`; создастся **БД** и `auth.json`.

---

## URL’ы

- **Обработчик бота** (Bitrix24):  
  `http://<домен>/<instance>/python_bot/`
- **Ваш API**:
  - Диалоги (GET):  
    `http://<домен>/<instance>/api/dialogs`
  - Диалог подробно (GET):  
    `http://<домен>/<instance>/api/dialogs/<chat_id>`
  - Пользователи (GET):  
    `http://<домен>/<instance>/api/users`
- **Админ-эндпойнты** (по токену через `?token=` или заголовок `X-API-Token`):
  - Включить:  `POST http://<домен>/<instance>/api/admin/enable?token=…`
  - Выключить: `POST http://<домен>/<instance>/api/admin/disable?token=…`
  - Статус:    `GET  http://<домен>/<instance>/api/admin/status?token=…`
  - (опц.) Переинициализация БД: `POST /api/admin/reinit_db?token=…` — если добавили в код

### Пример вызова API
```bash
# включить бота
curl -X POST "http://<домен>/<instance>/api/admin/enable?token=<API_SECRET_TOKEN>"
```

---

## Управление инстансами

`/usr/local/bin/botctl`:
```bash
sudo botctl <instance> on        # включить (создать ENABLED, запустить сервис)
sudo botctl <instance> off       # выключить (остановить сервис, создать DISABLED)
sudo botctl <instance> status    # статус systemd + runtime-флаг
sudo botctl <instance> restart   # перезапустить сервис
sudo botctl <instance> enable    # systemd enable
sudo botctl <instance> disable   # systemd disable
sudo botctl <instance> purge     # ПОЛНОЕ удаление инстанса(Бота-API)
```
`purge` удаляет: systemd-юнит, `/var/www/b24bots/<instance>`, запись в `ports.map`, env-файл, nginx-сниппеты (и vhost домена, если он пуст), затем валидирует и перезагружает Nginx.

---

## Секреты и безопасность

- **Админ-токен** хранится в:  
  `/etc/b24bot/env/<instance>.env` (строка `API_SECRET_TOKEN=...`).
- Сменить токен:
  ```bash
  sudo nano /etc/b24bot/env/<instance>.env
  sudo systemctl restart gunicorn-b24bot-<instance>
  ```
- В `main.py` токен читается так:  
  `API_SECRET_TOKEN = os.environ.get('API_SECRET_TOKEN', '...')`

> Это **не** `application_token` Bitrix24. Его присылает Б24 на `ONAPPINSTALL`, и бот сохраняет в `auth.json`.

---

## База данных

Создаётся:
1) установщиком (`main.init_db()`);
2) в обработчике `ONAPPINSTALL` (`init_db()` идемпотентен).

Если удалить `dialogs.db`, она создастся при переустановке приложения (или автоматически при старте, если добавлена функция `ensure_db_exists()`).

---

## Логи и диагностика
```bash
# Логи приложения
tail -f /var/www/b24bots/<instance>/bot.log

# Статус сервиса
systemctl status gunicorn-b24bot-<instance>
journalctl -u gunicorn-b24bot-<instance> -n 200 --no-pager

# Nginx
sudo nginx -t && sudo systemctl reload nginx
sudo tail -n 100 /var/log/nginx/access.log
sudo tail -n 200 /var/log/nginx/error.log
```

Если домен кириллический — в Nginx он будет как Punycode, но в браузере можно использовать «человекочитаемый» вид.

---

## Обновление кода
```bash
cd /var/www/b24bots/<instance>
sudo -u www-data git pull          # если инстанс развёрнут из git
sudo systemctl restart gunicorn-b24bot-<instance>
```

---

## Требования
- Ubuntu/Debian с `nginx`, `python3`, `python3-venv`, `git`, `sqlite3`, `curl`
- Открыт порт `80/tcp` (если UFW включён):
  ```bash
  sudo ufw allow 80/tcp
  ```

---

## Известные нюансы
- В Bitrix24 **обязательно** ставьте слэш в конце пути обработчика: `/python_bot/` — иначе будет `404`.
- Несколько инстансов на один домен поддерживаются через префиксы: `/client1/…`, `/client2/…`.
- Конфликт `default_server` в Nginx решается отключением старых конфигов `b24bots`/`default`.
- Для DuckDNS скрипт создаёт `cron` на обновление IP.

---

## Лицензия
MIT (если не указано иначе в исходном репозитории).
