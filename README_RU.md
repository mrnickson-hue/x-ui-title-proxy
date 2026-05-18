# x-ui-title-proxy

Лёгкий HTTPS reverse proxy для [3X-UI](https://github.com/MHSanaei/3x-ui), который заменяет заголовок вкладки браузера на любой произвольный текст — без модификации самой панели.

**До:** `node4.example.com - Inbounds`  
**После:** `My VPN Server (NODE1) - Inbounds`

Заголовок читается из конфигурационного файла при каждом запросе — менять его можно в любой момент **без перезапуска** прокси.

> **Почему это появилось?** Предложение добавить управление заголовком вкладки напрямую в админку 3X-UI было отправлено разработчику проекта, но осталось без ответа. Поэтому был написан этот прокси как самодостаточная альтернатива — без модификации панели, без ожидания апстрима.

---

## Как это работает

```
Браузер → :5555 (x-ui-title-proxy) → :5554 (3X-UI панель)
```

Прокси стоит перед вашей 3X-UI панелью. Для каждого HTML-ответа он:

1. Извлекает CSP nonce из заголовков ответа (3X-UI использует строгую Content Security Policy)
2. Вставляет небольшой тег `<script>` с nonce в `<head>`
3. Скрипт заменяет `document.title` при загрузке страницы, сохраняя суффикс с названием раздела (например, ` - Inbounds`, ` - Settings`)

Всё остальное — API-запросы, WebSocket, статика — проксируется прозрачно.

---

## Требования

- Linux (amd64 или arm64)
- Установленная и работающая панель 3X-UI
- SSL-сертификат для вашего домена (например, выпущенный через Let's Encrypt / acme.sh)

---

## Быстрая установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/mrnickson-hue/x-ui-title-proxy/main/install.sh)
```

Установщик задаст несколько вопросов:

| Вопрос | По умолчанию | Описание |
|--------|--------------|----------|
| Порт прокси | `5555` | Публичный порт, к которому подключаются пользователи |
| Порт бэкенда 3X-UI | `5554` | Порт, на котором работает панель внутри сервера |
| SSL-сертификат | **автоопределение** | Путь к fullchain-сертификату |
| SSL-ключ | **автоопределение** | Путь к приватному ключу |
| Заголовок вкладки | `My VPN Server` | Текст, который будет отображаться в браузере |

> **Автоопределение SSL:** установщик сначала читает пути к сертификатам напрямую из базы данных 3X-UI (`webCertFile` / `webKeyFile`). Если в панели сертификат не настроен — сканирует стандартные расположения: acme.sh (`~/.acme.sh/<domain>_ecc/`), certbot (`/etc/letsencrypt/live/<domain>/`), `/etc/x-ui/ssl/`. Найденный путь подставляется как значение по умолчанию — достаточно нажать Enter.

После установки нужно перевести панель 3X-UI на внутренний порт (см. [Настройка порта панели](#настройка-порта-панели)).

---

## Настройка порта панели

3X-UI должна слушать на **внутреннем порту** (например, `5554`), чтобы прокси мог передавать ей запросы.

**Вариант А — через веб-интерфейс 3X-UI:**  
Настройки → Настройки панели → Порт панели → установить `5554` → Сохранить

**Вариант Б — через SQLite (если панель недоступна):**

```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value=5554 WHERE key='webPort';"
systemctl start x-ui
```

> **Важно:** остановите x-ui перед редактированием базы данных — иначе панель перезапишет изменения при рестарте.

---

## Расположение SSL-сертификатов

Установщик определяет сертификат автоматически, но если нужно найти его вручную — расположение зависит от способа выпуска:

| Способ выпуска SSL | Сертификат | Приватный ключ |
|--------------------|------------|----------------|
| Встроенный инструмент 3X-UI (`x-ui ssl`) | `/etc/x-ui/ssl/fullchain.cer` | `/etc/x-ui/ssl/<домен>.key` |
| acme.sh (вручную) | `~/.acme.sh/<домен>_ecc/fullchain.cer` | `~/.acme.sh/<домен>_ecc/<домен>.key` |
| Certbot / Let's Encrypt | `/etc/letsencrypt/live/<домен>/fullchain.pem` | `/etc/letsencrypt/live/<домен>/privkey.pem` |

Самый быстрый способ узнать — спросить у самой 3X-UI (пути хранятся в её базе данных):

```bash
sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key IN ('webCertFile','webKeyFile');"
```

---

## Конфигурация

Файл конфигурации: `/etc/x-ui-proxy/config.json`

```json
{
  "listen":  ":5555",
  "backend": "https://127.0.0.1:5554",
  "cert":    "/etc/x-ui/ssl/fullchain.cer",
  "key":     "/etc/x-ui/ssl/your-domain.key",
  "title":   "My VPN Server (NODE1)"
}
```

| Поле | Описание |
|------|----------|
| `listen` | Адрес и порт, на котором слушает прокси |
| `backend` | Полный URL панели 3X-UI (обязательно HTTPS) |
| `cert` | Путь к SSL-сертификату (fullchain) |
| `key` | Путь к приватному SSL-ключу |
| `title` | Текст, отображаемый во вкладке браузера |

### Смена заголовка

Отредактируйте конфигурационный файл — **перезапуск не нужен**, изменения применятся при следующей загрузке страницы:

```bash
nano /etc/x-ui-proxy/config.json
```

---

## Управление сервисом

```bash
# Статус и логи
systemctl status x-ui-proxy
journalctl -u x-ui-proxy -f

# Перезапуск
systemctl restart x-ui-proxy

# Остановка / отключение автозапуска
systemctl stop x-ui-proxy
systemctl disable x-ui-proxy
```

---

## Ручная установка

Если вы предпочитаете установить вручную или собрать из исходников:

### Скачать готовый бинарь

```bash
# amd64
curl -sSfL https://github.com/mrnickson-hue/x-ui-title-proxy/releases/latest/download/x-ui-proxy-linux-amd64 \
  -o /usr/local/bin/x-ui-proxy && chmod +x /usr/local/bin/x-ui-proxy

# arm64
curl -sSfL https://github.com/mrnickson-hue/x-ui-title-proxy/releases/latest/download/x-ui-proxy-linux-arm64 \
  -o /usr/local/bin/x-ui-proxy && chmod +x /usr/local/bin/x-ui-proxy
```

### Собрать из исходников

```bash
git clone https://github.com/mrnickson-hue/x-ui-title-proxy.git
cd x-ui-title-proxy
CGO_ENABLED=0 go build -ldflags="-s -w" -o /usr/local/bin/x-ui-proxy .
```

### Создать конфигурацию

```bash
mkdir -p /etc/x-ui-proxy
cp config.example.json /etc/x-ui-proxy/config.json
nano /etc/x-ui-proxy/config.json
```

### Установить systemd-сервис

```bash
cp x-ui-proxy.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now x-ui-proxy
```

---

## Обновление

Повторно запустите установщик — он скачает последний бинарь. Файл конфигурации не затрагивается:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/mrnickson-hue/x-ui-title-proxy/main/install.sh)
```

---

## Удаление

```bash
systemctl disable --now x-ui-proxy
rm /usr/local/bin/x-ui-proxy
rm /etc/systemd/system/x-ui-proxy.service
rm -rf /etc/x-ui-proxy
systemctl daemon-reload
```

---

## Решение проблем

**Прокси запустился, но панель отдаёт 403**  
Проверьте, не установлен ли параметр `webDomain` в настройках 3X-UI — он блокирует запросы по имени хоста. Удалите его:
```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='webDomain';"
systemctl start x-ui
```

**Заголовок не меняется**  
Убедитесь, что подключаетесь к порту прокси, а не напрямую к панели. Проверьте `config.json` — правильный ли указан порт в `listen`.

**Сервис не запускается**  
Проверьте, что файлы сертификата и ключа существуют и доступны для чтения:
```bash
journalctl -u x-ui-proxy --no-pager -n 20
ls -la /etc/x-ui/ssl/
```

**Порт уже занят**  
Другой процесс (скорее всего сама x-ui) уже занимает этот порт. Убедитесь, что панель переведена на внутренний порт до запуска прокси.

---

## Лицензия

MIT
