# -*- coding: utf-8 -*-
import requests
from flask import Flask, request, jsonify, abort
import logging
import json
import os
import sqlite3
from datetime import datetime, timedelta, time
from functools import wraps

# --- Базовая директория инстанса (каталог, где лежит этот файл) ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# --- Файлы инстанса ---
LOG_FILE  = os.path.join(BASE_DIR, "bot.log")
AUTH_FILE = os.path.join(BASE_DIR, "auth.json")
DB_FILE   = os.path.join(BASE_DIR, "dialogs.db")

# Файлы-флаги для мягкого включения/выключения
ENABLED_FLAG  = os.path.join(BASE_DIR, "ENABLED")   # если нужен явный "включен"
DISABLED_FLAG = os.path.join(BASE_DIR, "DISABLED")  # если существует — бот выключен

# Секретный токен для доступа к API (можно задать через ENV: API_SECRET_TOKEN)
API_SECRET_TOKEN = os.environ.get('API_SECRET_TOKEN', 'asd1a2s3d4asd41a23sdas4d')

# --- Логирование ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

app = Flask(__name__)

# ---------------------- Утилиты ----------------------
def bot_enabled() -> bool:
    """
    Мягкое включение/выключение:
    - если есть файл DISABLED -> выключен
    - иначе включен (даже если файла ENABLED нет)
    """
    if os.path.exists(DISABLED_FLAG):
        return False
    return True  # default: enabled

def public_handler_url():
    """
    Строит публичный URL обработчика с учётом префикса, который добавляет Nginx.
    Nginx передаёт заголовок X-Forwarded-Prefix: "/<instance>"
    """
    proto  = request.headers.get('X-Forwarded-Proto', request.scheme or 'http')
    prefix = request.headers.get('X-Forwarded-Prefix', '')
    # request.path == "/python_bot/" внутри Flask (префикс уже срезан Nginx-ом)
    public_path = (prefix.rstrip('/') + request.path) if prefix else request.path
    return f"{proto}://{request.host}{public_path}"

# ---------------------- Работа с БД ----------------------
def init_db():
    """Инициализирует базу данных и создает таблицы, если их нет."""
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        cur.execute('''
            CREATE TABLE IF NOT EXISTS dialogs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER UNIQUE,
                start_time TEXT
            )
        ''')
        cur.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                user_name TEXT,
                role TEXT
            )
        ''')
        cur.execute('''
            CREATE TABLE IF NOT EXISTS dialog_participants (
                dialog_id INTEGER,
                user_id INTEGER,
                FOREIGN KEY (dialog_id) REFERENCES dialogs (id),
                FOREIGN KEY (user_id) REFERENCES users (id),
                PRIMARY KEY (dialog_id, user_id)
            )
        ''')
        cur.execute('''
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                dialog_chat_id INTEGER,
                author_id INTEGER,
                message_text TEXT,
                timestamp TEXT,
                FOREIGN KEY (dialog_chat_id) REFERENCES dialogs (chat_id),
                FOREIGN KEY (author_id) REFERENCES users (id)
            )
        ''')
        con.commit()
        con.close()
        logging.info("Database initialized successfully.")
    except Exception as e:
        logging.error(f"Error initializing database: {e}")

def save_new_dialog(chat_id):
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        start_time = datetime.now().isoformat()
        cur.execute(
            "INSERT OR IGNORE INTO dialogs (chat_id, start_time) VALUES (?, ?)",
            (chat_id, start_time)
        )
        con.commit()
        con.close()
        logging.info(f"Saved new dialog with chat_id: {chat_id}")
    except Exception as e:
        logging.error(f"Error saving new dialog {chat_id}: {e}")

def save_message(chat_id, author_id, message_text):
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        timestamp = datetime.now().isoformat()
        cur.execute(
            "INSERT INTO messages (dialog_chat_id, author_id, message_text, timestamp) VALUES (?, ?, ?, ?)",
            (chat_id, author_id, message_text, timestamp)
        )
        con.commit()
        con.close()
        logging.info(f"Saved message from {author_id} in chat {chat_id}")
    except Exception as e:
        logging.error(f"Error saving message in chat {chat_id}: {e}")

# ---------------------- Авторизация Б24 ----------------------
def save_auth_data(auth_payload):
    """Сохраняет данные авторизации в файл."""
    app_token = auth_payload.get('application_token')
    if app_token:
        try:
            with open(AUTH_FILE, 'w') as f:
                json.dump(auth_payload, f, indent=2)
            logging.info(f"Auth data for {app_token} saved to {AUTH_FILE}.")
            return True
        except Exception as e:
            logging.error(f"Failed to save auth data to {AUTH_FILE}: {e}")
            return False

def get_current_auth():
    if not os.path.exists(AUTH_FILE):
        return None
    try:
        with open(AUTH_FILE, 'r') as f:
            return json.load(f)
    except Exception as e:
        logging.error(f"Failed to read auth data from {AUTH_FILE}: {e}")
        return None

def rest_command(auth_data, method, params=None):
    if params is None:
        params = {}
    api_url = f"{auth_data['client_endpoint']}{method}"
    params['auth'] = auth_data['access_token']
    try:
        response = requests.post(api_url, json=params, timeout=15)
        response.raise_for_status()
        js = response.json()
        if 'error' in js:
            logging.error(f"Bitrix error for {method}: {js}")
        else:
            logging.info(f"Sent command {method}, response OK")
        return js
    except requests.exceptions.RequestException as e:
        logging.error(f"Error sending REST command {method}: {e}")
        try:
            return {'error': str(e), 'details': response.json()}
        except Exception:
            return {'error': str(e), 'details': getattr(response, 'text', 'no body')}

# ---------------------- Хелперы ----------------------
def parse_bitrix_data(post_data):
    output = {}
    for key, value in post_data.items():
        keys = key.replace(']', '').split('[')
        d = output
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value
    return output

def get_dialog_id(chat_id):
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        cur.execute("SELECT id FROM dialogs WHERE chat_id = ?", (chat_id,))
        result = cur.fetchone()
        con.close()
        return result[0] if result else None
    except Exception as e:
        logging.error(f"Error checking dialog {chat_id}: {e}")
        return None

def add_user(user_id, user_name, role='manager'):
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        cur.execute("INSERT OR IGNORE INTO users (id, user_name, role) VALUES (?, ?, ?)", (user_id, user_name, role))
        cur.execute("UPDATE users SET user_name = ?, role = ? WHERE id = ?", (user_name, role, user_id))
        con.commit()
        con.close()
    except Exception as e:
        logging.error(f"Error adding/updating user {user_id}: {e}")

def add_participant_to_dialog(chat_id, user_id):
    try:
        con = sqlite3.connect(DB_FILE)
        cur = con.cursor()
        cur.execute("SELECT id FROM dialogs WHERE chat_id = ?", (chat_id,))
        row = cur.fetchone()
        if not row:
            logging.error(f"add_participant_to_dialog: dialog {chat_id} not found")
            con.close()
            return
        dialog_db_id = row[0]
        cur.execute("INSERT OR IGNORE INTO dialog_participants (dialog_id, user_id) VALUES (?, ?)", (dialog_db_id, user_id))
        con.commit()
        con.close()
    except Exception as e:
        logging.error(f"Error adding participant {user_id} to chat {chat_id}: {e}")

def update_participants_for_dialog(chat_id, auth_data):
    logging.info(f"Updating participants for chat_id: {chat_id}")
    chat_get_result = rest_command(auth_data, 'im.chat.get', {'CHAT_ID': chat_id})
    if not chat_get_result or 'result' not in chat_get_result or 'users' not in chat_get_result['result']:
        logging.error(f"Failed to get chat users for chat_id {chat_id}. Response: {chat_get_result}")
        return
    user_ids = chat_get_result['result']['users'] or []
    if not user_ids:
        return
    users_get_result = rest_command(auth_data, 'user.get', {'ID': user_ids})
    if not users_get_result or 'result' not in users_get_result:
        logging.error(f"Failed to get user details for IDs {user_ids}. Response: {users_get_result}")
        if users_get_result and isinstance(users_get_result.get('details'), dict) and users_get_result['details'].get('error') == 'insufficient_scope':
            logging.error("CRITICAL: Missing 'user' scope. Add it in app settings and reinstall.")
        return
    for user in users_get_result['result']:
        user_id = user.get('ID')
        user_name = f"{user.get('NAME', '')} {user.get('LAST_NAME', '')}".strip()
        add_user(user_id, user_name)
        add_participant_to_dialog(chat_id, user_id)

# ---------------------- Безопасность API ----------------------
def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = None
        if 'Authorization' in request.headers:
            try:
                token_type, token = request.headers['Authorization'].split()
                if token_type.lower() != 'bearer':
                    return json.dumps({'message': 'Invalid token type. Use Bearer token.'}), 401, {'Content-Type': 'application/json'}
            except ValueError:
                return json.dumps({'message': 'Bearer token malformed'}), 401, {'Content-Type': 'application/json'}
        if not token:
            return json.dumps({'message': 'Token is missing!'}), 401, {'Content-Type': 'application/json'}
        if token != API_SECRET_TOKEN:
            return json.dumps({'message': 'Token is invalid!'}), 401, {'Content-Type': 'application/json'}
        return f(*args, **kwargs)
    return decorated

# ---------------------- Админ-эндпойнты включения/выключения ----------------------
def _admin_check():
    tok = request.args.get('token') or request.headers.get('X-API-Token')
    if tok != API_SECRET_TOKEN:
        abort(403)

@app.route('/api/admin/enable', methods=['POST'])
def admin_enable():
    _admin_check()
    # Удаляем жёсткий флаг выключения
    if os.path.exists(DISABLED_FLAG):
        os.remove(DISABLED_FLAG)
    # (Опционально) создаём ENABLED как маркер
    try:
        with open(ENABLED_FLAG, 'w') as _:
            pass
    except Exception:
        pass
    return jsonify({'ok': True, 'enabled': True})

@app.route('/api/admin/disable', methods=['POST'])
def admin_disable():
    _admin_check()
    # Создаём флаг выключения
    with open(DISABLED_FLAG, 'w') as _:
        pass
    return jsonify({'ok': True, 'enabled': False})

@app.route('/api/admin/status', methods=['GET'])
def admin_status():
    _admin_check()
    return jsonify({'ok': True, 'enabled': bot_enabled()})

# ---------------------- Глобальный guard для мягкого OFF ----------------------
@app.before_request
def guard():
    # служебные/админ-эндпойнты не блокируем
    if request.path.startswith('/api/admin'):
        return
    # если бот "выключен" — глушим входящие вебхуки Б24
    if request.method == 'POST' and request.path.endswith('/python_bot/') and not bot_enabled():
        return ('', 204)

# ---------------------- Публичные API ----------------------
def get_time_range_utc(args):
    date_str = args.get('date')
    if date_str:
        target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
    else:
        target_date = datetime.utcnow().date()
    tz_offset_hours = int(args.get('tz_offset', 0))
    tz_delta = timedelta(hours=tz_offset_hours)
    start_work_str = args.get('start_time', '00:00')
    end_work_str   = args.get('end_time',   '23:59')
    start_work_time = time.fromisoformat(start_work_str)
    end_work_time   = time.fromisoformat(end_work_str)
    local_start_dt = datetime.combine(target_date, start_work_time)
    local_end_dt   = datetime.combine(target_date, end_work_time)
    start_utc = local_start_dt - tz_delta
    end_utc   = local_end_dt   - tz_delta
    return start_utc.isoformat(), end_utc.isoformat()

@app.route('/api/dialogs', methods=['GET'])
@token_required
def get_dialogs():
    try:
        start_utc_str, end_utc_str = get_time_range_utc(request.args)
        con = sqlite3.connect(DB_FILE)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute(
            "SELECT id, chat_id, start_time FROM dialogs WHERE start_time BETWEEN ? AND ? ORDER BY start_time DESC",
            (start_utc_str, end_utc_str)
        )
        dialogs = [dict(row) for row in cur.fetchall()]
        con.close()
        return json.dumps(dialogs), 200, {'Content-Type': 'application/json'}
    except Exception as e:
        logging.error(f"API Error in get_dialogs: {e}")
        return json.dumps({'error': str(e)}), 500, {'Content-Type': 'application/json'}

@app.route('/api/dialogs/<int:chat_id>', methods=['GET'])
@token_required
def get_dialog_details(chat_id):
    try:
        start_utc_str, end_utc_str = get_time_range_utc(request.args)
        con = sqlite3.connect(DB_FILE)
        con.row_factory = sqlite3.Row
        cur = con.cursor()

        cur.execute("SELECT id, chat_id, start_time FROM dialogs WHERE chat_id = ?", (chat_id,))
        dialog_info = cur.fetchone()
        if not dialog_info:
            return json.dumps({'error': 'Dialog not found'}), 404, {'Content-Type': 'application/json'}

        dialog_db_id = dialog_info['id']
        result = dict(dialog_info)

        cur.execute("""
            SELECT u.id, u.user_name, u.role 
            FROM users u
            JOIN dialog_participants dp ON u.id = dp.user_id
            WHERE dp.dialog_id = ?
        """, (dialog_db_id,))
        result['participants'] = [dict(row) for row in cur.fetchall()]

        cur.execute("""
            SELECT m.id, m.author_id, u.user_name as author_name, m.message_text, m.timestamp 
            FROM messages m
            LEFT JOIN users u ON m.author_id = u.id
            WHERE m.dialog_chat_id = ? AND m.timestamp BETWEEN ? AND ?
            ORDER BY m.timestamp ASC
        """, (chat_id, start_utc_str, end_utc_str))
        result['messages'] = [dict(row) for row in cur.fetchall()]

        con.close()
        return json.dumps(result, ensure_ascii=False), 200, {'Content-Type': 'application/json; charset=utf-8'}
    except Exception as e:
        logging.error(f"API Error in get_dialog_details for chat {chat_id}: {e}")
        return json.dumps({'error': str(e)}), 500, {'Content-Type': 'application/json'}

@app.route('/api/users', methods=['GET'])
@token_required
def get_users():
    try:
        con = sqlite3.connect(DB_FILE)
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        cur.execute("SELECT id, user_name, role FROM users")
        users = [dict(row) for row in cur.fetchall()]
        con.close()
        return json.dumps(users), 200, {'Content-Type': 'application/json'}
    except Exception as e:
        logging.error(f"API Error in get_users: {e}")
        return json.dumps({'error': str(e)}), 500, {'Content-Type': 'application/json'}

# ---------------------- Вебхук бота ----------------------
@app.route('/python_bot/', methods=['POST'])
def webhook_handler():
    data = parse_bitrix_data(request.form)
    event = data.get('event')

    auth_from_request = data.get('auth', {})
    if not auth_from_request.get('application_token'):
        auth_from_request['application_token'] = data.get('auth[application_token]')
    app_token = auth_from_request.get('application_token')

    logging.info(f"Received event: {event} with app_token: {app_token}")

    if event == 'ONAPPINSTALL':
        logging.info("Handling ONAPPINSTALL event.")
        if not save_auth_data(auth_from_request):
            return "Failed to save auth", 500

        handler_url = public_handler_url()  # ключевая правка: учитываем X-Forwarded-Prefix

        result = rest_command(auth_from_request, 'imbot.register', {
            'CODE': 'py_interceptor_bot',
            'TYPE': 'O',
            'EVENT_WELCOME_MESSAGE': handler_url,
            'EVENT_MESSAGE_ADD':    handler_url,
            'EVENT_BOT_DELETE':     handler_url,
            'PROPERTIES': {
                'NAME': 'Python Interceptor Bot',
                'WORK_POSITION': 'Перехват и передача диалогов',
                'COLOR': 'AQUA',
            }
        })
        if result and 'result' in result:
            logging.info(f"Bot registered with ID: {result.get('result')}")
        else:
            logging.error(f"Failed to register bot. Response: {result}")
        return "OK"

    auth_data = get_current_auth()
    if not auth_data:
        logging.warning(f"No auth data in {AUTH_FILE}. Please install the app first.")
        return "Unauthorized", 401

    if auth_data.get('application_token') != app_token:
        logging.warning(f"Mismatched token! Expected {auth_data.get('application_token')}, got {app_token}")
        return "Forbidden", 403

    if event == 'ONIMBOTJOINCHAT':
        params = data.get('data', {}).get('PARAMS', {})
        user_info = data.get('data', {}).get('USER', {})
        chat_id_str = params.get('CHAT_ID')
        user_id = user_info.get('ID')
        user_name = user_info.get('NAME')

        if chat_id_str and user_id:
            chat_id = int(chat_id_str)
            if not get_dialog_id(chat_id):
                save_new_dialog(chat_id)
            add_user(user_id, user_name, 'client')  # инициатор — клиент
            add_participant_to_dialog(chat_id, user_id)
            logging.info(f"Bot joined chat {chat_id}. Transferring to operator queue...")
            rest_command(auth_data, 'imopenlines.bot.session.transfer', {
                'CHAT_ID': chat_id,
                'QUEUE': 'Y',
                'LEAVE': 'Y'
            })

    elif event == 'ONIMBOTMESSAGEADD':
        params = data.get('data', {}).get('PARAMS', {})
        user_info = data.get('data', {}).get('USER', {})

        chat_id_str  = params.get('CHAT_ID')
        author_id    = params.get('AUTHOR_ID')
        author_name  = user_info.get('NAME', '')
        message_text = params.get('MESSAGE')

        is_extranet  = user_info.get('IS_EXTRANET') == 'Y'
        author_role  = 'client' if is_extranet else 'manager'

        if chat_id_str and author_id and message_text:
            chat_id = int(chat_id_str)
            if not get_dialog_id(chat_id):
                save_new_dialog(chat_id)
            add_user(author_id, author_name, author_role)
            add_participant_to_dialog(chat_id, author_id)
            save_message(chat_id, author_id, message_text)

    return "OK"

# ---------------------- Точка входа ----------------------
if __name__ == '__main__':
    logging.info("Starting Flask server for local debug...")
    init_db()
    app.run(host='0.0.0.0', port=8080, debug=True)
