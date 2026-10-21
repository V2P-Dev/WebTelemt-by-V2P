#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
# Telegram WEB proxy installer: Telemt (WEB mode) behind Caddy. Ubuntu 24.04.
# Supported usage (the script carries a bundled payload, so it must be a real file):
#   curl -fsSL URL -o webproxy-install.sh && sudo bash webproxy-install.sh
set -Eeuo pipefail

TELEMT_VERSION="${TELEMT_VERSION:-3.5.14}"
DOMAIN="${DOMAIN:-}"
DECOY="${DECOY:-}"
EMAIL="${EMAIL:-}"
NEW_SECRET=0
SKIP_DNS=0
ASSUME_YES=0
FORCE=0
SELF="${BASH_SOURCE[0]:-$0}"
TMP_DIR=""
STEP=0
TOTAL=10
SHARE_DIR=/usr/local/share/webproxy
PUBLIC_DIR=/var/lib/telemt/public
TOML=/etc/telemt/telemt.toml
CLI=/usr/local/bin/webproxy

if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_N=$'\e[0m'
else
  C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_N=""
fi

step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$C_B$C_C" "$STEP" "$TOTAL" "$1" "$C_N"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '\n%s✘ %s%s\n' "$C_R" "$*" "$C_N" >&2; exit 1; }

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT
trap 'printf "%s✘ Ошибка в строке %s%s\n" "$C_R" "$LINENO" "$C_N" >&2' ERR

usage() {
  cat <<'EOF'
Установщик Telegram WEB-прокси (Telemt + Caddy) для Ubuntu 24.04.

Использование:
  curl -fsSL https://raw.githubusercontent.com/V2P-Dev/WebTelemt-by-V2P/main/webproxy-install.sh -o webproxy-install.sh && sudo bash webproxy-install.sh [опции]

Опции:
  --domain D          домен прокси (A-запись должна указывать на этот сервер)
  --decoy N           страница-заглушка 1..3
  --email E           e-mail для Let's Encrypt (необязательно)
  --telemt-version V  версия Telemt (по умолчанию 3.5.14, либо latest)
  --new-secret        сгенерировать новый секрет, даже если конфиг уже есть
  --skip-dns-check    не проверять DNS
  -y, --yes           без вопросов (ошибка, если не хватает значений)
  --force             не проверять версию ОС
  -h, --help          эта справка

Переменные окружения: DOMAIN, DECOY, EMAIL.
Порт 443 обязателен: клиенты Telegram подключаются к WEB-прокси только по 443.
EOF
}

# ---------- arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|--decoy|--email|--telemt-version)
      [[ $# -ge 2 ]] || die "Опции $1 нужно значение"
      case "$1" in
        --domain) DOMAIN="$2" ;;
        --decoy) DECOY="$2" ;;
        --email) EMAIL="$2" ;;
        --telemt-version) TELEMT_VERSION="$2" ;;
      esac
      shift 2 ;;
    --new-secret) NEW_SECRET=1; shift ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Неизвестная опция: $1" ;;
  esac
done

# Run a command silently; show its tail only on failure.
quiet() {
  local out
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out" | tail -n 20 >&2
    return 1
  fi
}

conf_get() { # read KEY from an existing /etc/webproxy.conf without sourcing
  [[ -f /etc/webproxy.conf ]] || return 0
  sed -n "s/^$1=\"\(.*\)\"\$/\1/p" /etc/webproxy.conf | head -n 1
}

prompt() { # prompt "text" -> reply on stdout; returns 1 if there is no usable terminal
  local reply=""
  printf '%s' "$1" >&2
  { read -r reply </dev/tty; } 2>/dev/null || return 1
  printf '%s' "$reply"
}

# Hide secrets in log output
redact() { sed -u -E 's/(secret=)[^&[:space:]"]+/\1<скрыто>/g; s/[0-9a-fA-F]{32,}/<скрыто>/g'; }

extract_decoys() {
  local tmp="$1"
  [[ -f "$SELF" && -r "$SELF" ]] || die "Скрипт запущен не из файла. Скачайте его: curl -fsSL URL -o webproxy-install.sh && sudo bash webproxy-install.sh"
  grep -q '^__PAYLOAD_BELOW__$' "$SELF" || die "В скрипте нет встроенных заглушек (нужна собранная версия)"
  sed -n '/^__PAYLOAD_BELOW__$/,$p' "$SELF" | tail -n +2 | base64 -d | tar -xz -C "$tmp"
  [[ -d "$tmp/decoys" ]] || die "Повреждён архив заглушек"
  rm -rf "$SHARE_DIR/decoys"
  install -d -m 0755 "$SHARE_DIR"
  cp -a "$tmp/decoys" "$SHARE_DIR/decoys"
  chmod -R u=rwX,go=rX "$SHARE_DIR"
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]]
}

ensure_pkgs() {
  quiet apt-get -o DPkg::Lock::Timeout=600 install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# ---------- management CLI (installed to /usr/local/bin/webproxy) ----------
install_cli() {
  install -d -m 0755 /usr/local/bin
  cat > "$CLI" <<'WEBPROXY_CLI_EOF'
#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
# webproxy: management CLI for the Telemt WEB proxy
set -Eeuo pipefail

CONF=/etc/webproxy.conf
TOML=/etc/telemt/telemt.toml
LINKS=/root/webproxy-links.txt
SHARE_DIR=/usr/local/share/webproxy
DECOYS="$SHARE_DIR/decoys"
PUBLIC_DIR=/var/lib/telemt/public
BIN=/usr/local/bin/telemt
API=http://127.0.0.1:9091
DOMAIN="" DECOY="" TELEMT_VERSION="" CREATED_USER=""
CLI_TMP=""
PINNED_VERSION=3.5.14
PINNED_SHA_X86_64=71c1454f79cf755edea0985500629daba553002f9863be754e8e38a418822773
PINNED_SHA_AARCH64=21795430c4165cf964405459714d08eea319edaa5c9027beac4de373c356d84d
cleanup() { [[ -n "$CLI_TMP" && -d "$CLI_TMP" ]] && rm -rf "$CLI_TMP"; return 0; }
trap cleanup EXIT

if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_N=$'\e[0m'
else
  C_B=""; C_R=""; C_G=""; C_Y=""; C_N=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()  { printf '%s✘ %s%s\n' "$C_R" "$*" "$C_N" >&2; exit 1; }
trap 'printf "%s✘ Ошибка в строке %s%s\n" "$C_R" "$LINENO" "$C_N" >&2' ERR

need_root() { [[ $EUID -eq 0 ]] || die "Нужны права root: запустите через sudo (sudo webproxy ...)"; }

# Authorization header is passed via a file descriptor so the token stays out of process args
api_get() { # api_get PATH
  local tok
  tok=$(api_token)
  curl -s --max-time 10 "$API$1" -H @<(printf 'Authorization: %s\n' "$tok")
}

load_conf() {
  [[ -f "$CONF" ]] || die "Не найден $CONF: прокси не установлен?"
  # shellcheck disable=SC1090
  . "$CONF"
}

set_conf() { # set_conf KEY VALUE (only if conf exists)
  [[ -f "$CONF" ]] || return 0
  local t
  t=$(mktemp)
  grep -v "^$1=" "$CONF" > "$t" || true
  printf '%s="%s"\n' "$1" "$2" >> "$t"
  install -m 0600 "$t" "$CONF"
  rm -f "$t"
}

get_secret() { sed -n 's/^web-user = "\([0-9a-f]\{32\}\)"$/\1/p' "$TOML" | head -n 1; }
api_token() { sed -n 's/^auth_header = "\(.*\)"/\1/p' "$TOML" | head -n 1; }
decoy_name() { sed -n 1p "$DECOYS/$1/meta" 2>/dev/null || true; }

set_links() { # sets TG_LINK and WEB_LINK
  local s
  s=$(get_secret)
  [[ -n "$s" ]] || die "Секрет не найден в $TOML"
  TG_LINK="tg://webproxy?server=$DOMAIN&secret=dd$s"
  WEB_LINK="https://t.me/webproxy?server=$DOMAIN&secret=dd$s"
}

write_links() {
  set_links
  ( umask 077; printf '%s\n%s\n' "$TG_LINK" "$WEB_LINK" > "$LINKS" )
}

# ---- telemt reload (hot, drain) with polling ----
reload_telemt() {
  local tok resp id state i
  tok=$(api_token)
  [[ -n "$tok" ]] || return 1
  resp=$(curl -s --max-time 10 -X POST "$API/v1/system/reload" \
    -H @<(printf 'Authorization: %s\n' "$tok") \
    -H 'Content-Type: application/json' \
    -d '{"mode":"drain","timeout_secs":30,"failure_policy":"rollback"}') || return 1
  id=$(jq -r '.data.reload_id // empty' <<<"$resp" 2>/dev/null) || return 1
  [[ -n "$id" ]] || return 1
  for ((i = 0; i < 45; i++)); do
    state=$(api_get "/v1/system/reload/$id" \
      | jq -r '.data.state // empty' 2>/dev/null) || state=""
    case "$state" in
      succeeded) return 0 ;;
      failed|rolled_back) return 1 ;;
    esac
    sleep 2
  done
  return 1
}

apply_config() {
  info "Горячая перезагрузка Telemt (до ~30 с)..."
  if reload_telemt; then
    ok "Конфигурация применена (активные клиенты переподключатся автоматически)"
  else
    warn "Горячая перезагрузка не удалась, перезапускаю Telemt"
    systemctl restart telemt
  fi
}

# ---- telemt download + sha256 verification ----
resolve_version() {
  local v="${1:-latest}"
  if [[ "$v" == latest ]]; then
    v=$(curl -fsS --max-time 20 https://api.github.com/repos/telemt/telemt/releases/latest | jq -r '.tag_name // empty' || true)
    [[ -n "$v" ]] || die "Не удалось получить последнюю версию Telemt с GitHub"
  fi
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректная версия: $v"
  printf '%s' "$v"
}

install_telemt() {
  local ver arch asset base tmp expect actual
  ver=$(resolve_version "${1:-latest}")
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac
  asset="telemt-${arch}-linux-musl.tar.gz"
  base="https://github.com/telemt/telemt/releases/download/$ver"
  CLI_TMP=$(mktemp -d)
  tmp="$CLI_TMP"
  info "Скачиваю Telemt $ver ($arch)..."
  curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset" || die "Не удалось скачать $base/$asset"
  if [[ "$ver" == "$PINNED_VERSION" ]]; then
    if [[ "$arch" == x86_64 ]]; then expect="$PINNED_SHA_X86_64"; else expect="$PINNED_SHA_AARCH64"; fi
    info "Сверяю с зашитой в установщик контрольной суммой"
  else
    curl -fsSL --retry 3 -o "$tmp/$asset.sha256" "$base/$asset.sha256" || die "Не удалось скачать контрольную сумму"
    expect=$(awk '{print $1; exit}' "$tmp/$asset.sha256")
    warn "Версия $ver не закреплена: контрольная сумма взята из релиза (проверяется только целостность загрузки)"
  fi
  [[ "$expect" =~ ^[0-9a-fA-F]{64}$ ]] || die "Некорректная контрольная сумма"
  actual=$(sha256sum "$tmp/$asset" | awk '{print $1}')
  [[ "${expect,,}" == "$actual" ]] || die "SHA256 не совпадает (ожидалось $expect, получено $actual). Прерываю."
  ok "SHA256 проверен"
  mkdir "$tmp/x"
  tar -xzf "$tmp/$asset" -C "$tmp/x"
  [[ -f "$tmp/x/telemt" ]] || die "В архиве нет бинарника telemt"
  install -m 0755 "$tmp/x/telemt" "$BIN"
  set_conf TELEMT_VERSION "$ver"
  info "$("$BIN" --version 2>&1 | head -n 1)"
}

# ---- decoys ----
install_decoy() {
  local n="$1" src
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "Номер заглушки должен быть числом"
  src="$DECOYS/$n"
  [[ -d "$src" ]] || die "Нет заглушки №$n"
  install -d -m 0755 "$PUBLIC_DIR"
  find "$PUBLIC_DIR" -mindepth 1 -delete
  cp -a "$src/." "$PUBLIC_DIR/"
  rm -f "$PUBLIC_DIR/meta"
  chown -R telemt:telemt "$PUBLIC_DIR"
  find "$PUBLIC_DIR" -type d -exec chmod 0755 {} +
  find "$PUBLIC_DIR" -type f -exec chmod 0644 {} +
}

confirm() { # confirm "text" -> 0 on y/Y
  local r=""
  read -r -p "$1 [y/N] " r || true
  [[ "$r" == y || "$r" == Y ]]
}

# ---- commands ----
cmd_status() {
  load_conf
  local st exp sess
  for u in telemt caddy; do
    st=$(systemctl is-active "$u" 2>/dev/null || true)
    if [[ "$st" == active ]]; then ok "$u: работает"; else warn "$u: $st"; fi
  done
  info "Telemt:  $("$BIN" --version 2>&1 | head -n 1) (в конфиге: ${TELEMT_VERSION:-?})"
  info "Caddy:   $(caddy version 2>/dev/null | head -n 1 || echo н/д)"
  info "Домен:   $DOMAIN"
  info "Заглушка: ${DECOY:-?} ($(decoy_name "${DECOY:-0}"))"
  exp=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
  info "Сертификат до: ${exp:-н/д}"
  sess=$(api_get /v1/runtime/web/sessions 2>/dev/null \
    | jq -r '.data | if type=="array" then length elif type=="object" then (.total // .count // (.items // .sessions // [] | length)) else "н/д" end' 2>/dev/null || true)
  info "Активные WEB-сессии: ${sess:-н/д}"
}

cmd_links() {
  load_conf
  set_links
  info "$TG_LINK"
  info "$WEB_LINK"
  if [[ "${1:-}" == --qr ]]; then
    echo
    printf '%s' "$WEB_LINK" | qrencode -t ANSIUTF8
  fi
}

cmd_decoy() {
  load_conf
  local n="${1:-}" d i mark col
  if [[ -z "$n" ]]; then
    for d in "$DECOYS"/*/; do
      i=$(basename "$d")
      mark=" "; col=""
      if [[ "$i" == "${DECOY:-}" ]]; then mark="*"; col="$C_G"; fi
      printf '%s%s %s. %s%s\n     %s\n' "$col" "$mark" "$i" "$(sed -n 1p "$d/meta")" "$C_N" "$(sed -n 2p "$d/meta")"
    done
    info "Сменить: webproxy decoy N"
    return 0
  fi
  need_root
  install_decoy "$n"
  set_conf DECOY "$n"
  ok "Заглушка №$n установлена"
  apply_config
}

cmd_rotate() {
  need_root
  load_conf
  confirm "Старая ссылка перестанет работать. Сменить секрет?" || { info "Отменено"; return 0; }
  local bak t
  bak="$TOML.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$TOML" "$bak"
  # new secret goes through the environment, not the command line
  NEW_SECRET_HEX=$(openssl rand -hex 16)
  export NEW_SECRET_HEX
  t=$(mktemp "$TOML.XXXXXX")
  chmod 600 "$t"
  awk '/^web-user = "/ { print "web-user = \"" ENVIRON["NEW_SECRET_HEX"] "\""; next } { print }' "$TOML" > "$t"
  chown --reference="$TOML" "$t"
  chmod --reference="$TOML" "$t"
  mv -f "$t" "$TOML"
  unset NEW_SECRET_HEX
  apply_config
  write_links
  ok "Секрет обновлён (резервная копия: $bak)"
  cmd_links --qr
}

cmd_restart() {
  need_root
  systemctl restart telemt caddy
  ok "telemt и caddy перезапущены"
}

cmd_logs() {
  local unit=telemt follow=() a
  for a in "$@"; do
    case "$a" in
      telemt|caddy) unit="$a" ;;
      -f) follow=(-f) ;;
      *) die "Использование: webproxy logs [telemt|caddy] [-f]" ;;
    esac
  done
  journalctl -u "$unit" -n 100 --no-pager "${follow[@]}" \
    | sed -u -E 's/(secret=)[^&[:space:]"]+/\1<скрыто>/g; s/[0-9a-fA-F]{32,}/<скрыто>/g'
}

cmd_update() {
  need_root
  load_conf
  install_telemt "${1:-latest}"
  systemctl restart telemt
  ok "Telemt обновлён и перезапущен"
}

cmd_uninstall() {
  need_root
  local r="" bak
  # shellcheck disable=SC1090
  [[ -f "$CONF" ]] && . "$CONF"
  read -r -p "Удалить прокси полностью? Введите yes: " r || true
  [[ "$r" == yes ]] || { info "Отменено"; return 0; }
  local rm_caddy=0
  confirm "Удалить также пакет Caddy и его репозиторий?" && rm_caddy=1
  systemctl disable --now telemt 2>/dev/null || true
  rm -f /etc/systemd/system/telemt.service
  systemctl daemon-reload
  rm -f "$BIN"
  rm -rf /etc/telemt /var/lib/telemt "$SHARE_DIR"
  if [[ "${CREATED_USER:-}" == 1 ]]; then
    rm -rf /opt/telemt
    id telemt >/dev/null 2>&1 && { userdel telemt 2>/dev/null || true; }
    getent group telemt >/dev/null 2>&1 && { groupdel telemt 2>/dev/null || true; }
  else
    info "Пользователь telemt и /opt/telemt созданы не установщиком: оставлены"
  fi
  if [[ $rm_caddy -eq 1 ]]; then
    systemctl disable --now caddy 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 purge -y caddy >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    apt-get -o DPkg::Lock::Timeout=600 update >/dev/null 2>&1 || true
  else
    bak=$(ls -1 /etc/caddy/Caddyfile.bak-* 2>/dev/null | tail -n 1 || true)
    if [[ -n "$bak" ]]; then
      cp -a "$bak" /etc/caddy/Caddyfile
      systemctl restart caddy || true
      ok "Caddyfile восстановлен из $bak"
    else
      systemctl stop caddy 2>/dev/null || true
      info "Caddy остановлен (конфиг оставлен)"
    fi
  fi
  rm -f "$CONF" "$LINKS" /usr/local/bin/webproxy
  ok "Удалено. Правила ufw (80/443) не тронуты."
  exit 0
}

cmd_help() {
  cat <<'EOF'
webproxy: управление Telegram WEB-прокси

  status                  состояние сервисов, сертификат, сессии
  links [--qr]            ссылки для Telegram (и QR-код)
  decoy [N]               список заглушек / сменить на N
  rotate-secret           новый секрет (старые ссылки перестанут работать)
  restart                 перезапустить telemt и caddy
  logs [telemt|caddy] [-f] журнал (секреты скрыты)
  update [VERSION]        обновить Telemt (по умолчанию latest)
  uninstall               полное удаление
  help                    эта справка
EOF
}

main() {
  local c="${1:-help}"
  shift || true
  case "$c" in
    help|-h|--help) ;;
    *) need_root ;;
  esac
  case "$c" in
    status) cmd_status ;;
    links) cmd_links "$@" ;;
    decoy) cmd_decoy "$@" ;;
    rotate-secret) cmd_rotate ;;
    restart) cmd_restart ;;
    logs) cmd_logs "$@" ;;
    update) cmd_update "$@" ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) cmd_help ;;
    # internal, used by the installer
    _resolve-version) resolve_version "${1:-latest}" ;;
    _install-telemt) install_telemt "${1:-latest}" ;;
    _install-decoy) install_decoy "$1" ;;
    _write-links) load_conf; write_links ;;
    *) cmd_help >&2; exit 1 ;;
  esac
}
main "$@"
exit 0
WEBPROXY_CLI_EOF
  chmod 0755 "$CLI"
}

# ---------- installer steps ----------
check_system() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
  if [[ $FORCE -ne 1 ]]; then
    # shellcheck disable=SC1091
    local id ver
    id=$(. /etc/os-release && printf '%s' "${ID:-}")
    ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    [[ "$id" == ubuntu && "$ver" == 24.04 ]] || die "Нужна Ubuntu 24.04 (найдено: $id $ver). Используйте --force на свой риск."
  fi
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "Поддерживаются только x86_64 и aarch64 (найдено: $(uname -m))" ;;
  esac
}

collect_input() {
  local n name desc reply
  [[ -n "$DOMAIN" ]] || DOMAIN=$(conf_get DOMAIN)
  [[ -n "$DECOY" ]] || DECOY=$(conf_get DECOY)
  [[ -n "$EMAIL" ]] || EMAIL=$(conf_get EMAIL)

  if [[ -z "$DOMAIN" ]]; then
    [[ $ASSUME_YES -eq 0 ]] || die "Не задан домен (--domain или DOMAIN)"
    while :; do
      DOMAIN=$(prompt "Домен прокси (например proxy.example.com): ") || die "Нет терминала: передайте --domain/--decoy или -y"
      DOMAIN="${DOMAIN,,}"
      valid_domain "$DOMAIN" && break
      warn "Некорректный домен, попробуйте ещё раз"
    done
  fi
  DOMAIN="${DOMAIN,,}"
  valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"

  if [[ -z "$DECOY" ]]; then
    [[ $ASSUME_YES -eq 0 ]] || die "Не задана заглушка (--decoy 1..3 или DECOY)"
    printf '\nСтраница-заглушка (её видят все, кто откроет домен в браузере):\n' >&2
    for n in 1 2 3; do
      name=$(sed -n 1p "$SHARE_DIR/decoys/$n/meta" 2>/dev/null || true)
      desc=$(sed -n 2p "$SHARE_DIR/decoys/$n/meta" 2>/dev/null || true)
      printf '  %s%d)%s %s: %s\n' "$C_B" "$n" "$C_N" "$name" "$desc" >&2
    done
    while :; do
      DECOY=$(prompt "Номер заглушки [1-3]: ") || die "Нет терминала: передайте --domain/--decoy или -y"
      [[ "$DECOY" =~ ^[1-3]$ ]] && break
      warn "Введите 1, 2 или 3"
    done
  fi
  [[ "$DECOY" =~ ^[1-3]$ ]] || die "--decoy должен быть 1, 2 или 3"
  [[ -d "$SHARE_DIR/decoys/$DECOY" ]] || die "В пакете нет заглушки №$DECOY"

  if [[ -z "$EMAIL" && $ASSUME_YES -eq 0 && -r /dev/tty ]]; then
    reply=$(prompt "E-mail для Let's Encrypt (Enter, чтобы пропустить): ") || reply=""
    EMAIL="$reply"
  fi
  if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    die "Некорректный e-mail: $EMAIL"
  fi
}

detect_ip() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      PUBLIC_IP="$ip"
      return 0
    fi
  done
  die "Не удалось определить публичный IPv4 сервера"
}

dns_fail() {
  die "$1
Создайте A-запись: $DOMAIN -> $PUBLIC_IP, подождите обновления и запустите установщик снова."
}

check_dns() {
  local a aaaa srv have6
  for srv in 1.1.1.1 8.8.8.8; do
    a=$(dig +short A "$DOMAIN" "@$srv" 2>/dev/null | grep -E '^[0-9.]+$' || true)
    [[ -n "$a" ]] && break
  done
  [[ -n "${a:-}" ]] || dns_fail "У домена $DOMAIN нет A-записи."
  grep -Fxq "$PUBLIC_IP" <<<"$a" || dns_fail "A-запись $DOMAIN ($(tr '\n' ' ' <<<"$a")) не указывает на этот сервер ($PUBLIC_IP)."
  ok "DNS: $DOMAIN -> $PUBLIC_IP"
  aaaa=$(dig +short AAAA "$DOMAIN" "@1.1.1.1" 2>/dev/null | grep ':' || true)
  if [[ -n "$aaaa" ]]; then
    have6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    local ok6=0 addr
    while read -r addr; do
      [[ -n "$addr" ]] && grep -Fxqi "$addr" <<<"$have6" && ok6=1
    done <<<"$aaaa"
    [[ $ok6 -eq 1 ]] || die "У $DOMAIN есть AAAA-запись ($(tr '\n' ' ' <<<"$aaaa")), но такого IPv6 нет на сервере. Let's Encrypt предпочитает IPv6 и выпуск сертификата не удастся. Удалите AAAA-запись (или направьте её на этот сервер) и повторите."
  fi
}

port_check() { # port owner-regex
  local out
  out=$(ss -ltnpH "sport = :$1" 2>/dev/null || true)
  [[ -z "$out" ]] && return 0
  grep -Eq "\"($2)\"" <<<"$out" && return 0
  printf '%s\n' "$out" >&2
  die "Порт $1 занят другим процессом (см. выше). Освободите его и запустите установщик снова."
}

wait_ready() {
  local i=0 tele=0 https=0
  while ((i < 45)); do
    if [[ $tele -eq 0 ]] && ss -ltnH "sport = :18080" 2>/dev/null | grep -q '127.0.0.1:18080'; then
      tele=1; ok "Telemt слушает 127.0.0.1:18080"
    fi
    if [[ $tele -eq 1 ]] && curl -fsS -o /dev/null --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null; then
      https=1; ok "HTTPS работает, сертификат действителен"
      break
    fi
    sleep 2
    i=$((i + 1))
  done
  [[ $tele -eq 1 ]] || { journalctl -u telemt -n 20 --no-pager 2>&1 | redact >&2 || true; die "Telemt не запустился за 90 с"; }
  if [[ $https -ne 1 ]]; then
    warn "Сертификат пока не получен (Caddy продолжит попытки). Последние строки журнала Caddy:"
    journalctl -u caddy -n 20 --no-pager 2>&1 | redact >&2 || true
  fi
}

main() {
  local ts secret token backup caddy_bak created_user
  check_system
  TMP_DIR=$(mktemp -d)
  extract_decoys "$TMP_DIR"
  collect_input
  ts=$(date +%Y%m%d-%H%M%S)
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

  printf '%sWEB-прокси Telegram: домен %s, заглушка %s%s\n' "$C_B" "$DOMAIN" "$DECOY" "$C_N"

  step "Обновление системы"
  quiet apt-get -o DPkg::Lock::Timeout=600 update
  quiet env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  ok "Система обновлена"

  step "Установка зависимостей и утилиты webproxy"
  ensure_pkgs curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https openssl jq qrencode iproute2 dnsutils
  install_cli
  ok "Установлено: $CLI"

  step "Публичный IP и DNS"
  detect_ip
  ok "IPv4 сервера: $PUBLIC_IP"
  if [[ $SKIP_DNS -eq 1 ]]; then warn "Проверка DNS пропущена"; else check_dns; fi

  step "Проверка портов"
  port_check 80 caddy
  port_check 443 caddy
  port_check 18080 telemt
  port_check 9091 telemt
  ok "Порты 80, 443, 18080, 9091 доступны"

  step "Установка Caddy"
  if ! command -v caddy >/dev/null 2>&1 || [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    quiet apt-get -o DPkg::Lock::Timeout=600 update
    ensure_pkgs caddy
  fi
  ok "$(caddy version | head -n 1)"

  step "Установка Telemt"
  TELEMT_VERSION=$("$CLI" _resolve-version "$TELEMT_VERSION")
  "$CLI" _install-telemt "$TELEMT_VERSION"

  step "Конфигурация Telemt и заглушка"
  created_user=$(conf_get CREATED_USER)
  if ! id telemt >/dev/null 2>&1; then
    useradd -d /opt/telemt -m -r -U -s /usr/sbin/nologin telemt
    created_user=1
  fi
  install -d -m 0750 -o telemt -g telemt /opt/telemt
  install -d -m 0755 -o telemt -g telemt /var/lib/telemt "$PUBLIC_DIR"
  install -d -m 0750 -o telemt -g telemt /etc/telemt
  secret=""; token=""
  if [[ -f "$TOML" && $NEW_SECRET -ne 1 ]]; then
    secret=$(sed -n 's/^web-user = "\([0-9a-f]\{32\}\)"$/\1/p' "$TOML" | head -n 1 || true)
    token=$(sed -n 's/^auth_header = "Bearer \([0-9a-f]\{48\}\)"$/\1/p' "$TOML" | head -n 1 || true)
    [[ -n "$secret" ]] || die "В $TOML не удалось прочитать секрет web-user (32 hex). Не хочу молча менять ссылки: исправьте файл или запустите с --new-secret."
    ok "Секрет сохранён из прежнего конфига"
  fi
  [[ -n "$secret" ]] || secret=$(openssl rand -hex 16)
  [[ -n "$token" ]] || token=$(openssl rand -hex 24)
  if [[ -f "$TOML" ]]; then
    backup="$TOML.bak-$ts"
    cp -a "$TOML" "$backup"
    info "Резервная копия конфига: $backup"
  fi
  ( umask 077
    cat > "$TMP_DIR/telemt.toml" <<EOF
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = true
tls = false

[general.links]
show = ["web-user"]

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
auth_header = "Bearer $token"
read_only = false

[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"
proxy_protocol = false
reuse_allow = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https"

[[web.vhosts]]
host = "$DOMAIN"
public_addr = "$PUBLIC_IP:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "/var/lib/telemt/public"
index = "index.html"

[[web.vhosts.profiles]]
user = "web-user"
secret_mode = "dd"
max_sessions = 64
max_streams = 2048
max_streams_per_session = 64

[access.users]
web-user = "$secret"
EOF
  )
  install -m 0600 -o telemt -g telemt "$TMP_DIR/telemt.toml" "$TOML"
  "$CLI" _install-decoy "$DECOY"
  ok "Заглушка №$DECOY установлена"
  ( umask 077
    cat > /etc/webproxy.conf <<EOF
DOMAIN="$DOMAIN"
DECOY="$DECOY"
EMAIL="$EMAIL"
TELEMT_VERSION="$TELEMT_VERSION"
PUBLIC_IP="$PUBLIC_IP"
CREATED_USER="$created_user"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  )
  chmod 600 /etc/webproxy.conf

  step "Запуск сервисов (Telemt, Caddy, ufw)"
  cat > /etc/systemd/system/telemt.service <<'EOF'
[Unit]
Description=Telemt MTProxy (WEB mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/telemt /opt/telemt /var/lib/telemt
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable telemt >/dev/null 2>&1
  systemctl restart telemt
  ok "telemt.service запущен"

  if [[ -f /etc/caddy/Caddyfile ]] && ! grep -q '^# managed by webproxy' /etc/caddy/Caddyfile; then
    caddy_bak="/etc/caddy/Caddyfile.bak-$ts"
    cp -a /etc/caddy/Caddyfile "$caddy_bak"
    info "Чужой Caddyfile сохранён: $caddy_bak"
  fi
  {
    printf '# managed by webproxy\n{\n'
    [[ -z "$EMAIL" ]] || printf '\temail %s\n' "$EMAIL"
    printf '\tservers {\n\t\tprotocols h1 h2\n\t}\n}\n\n'
    printf '%s {\n' "$DOMAIN"
    printf '\treverse_proxy 127.0.0.1:18080 {\n'
    printf '\t\theader_up X-Forwarded-For {remote_host}\n'
    printf '\t\tflush_interval -1\n'
    printf '\t\tstream_close_delay 5m\n'
    printf '\t}\n}\n'
  } > /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || { caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >&2 || true; die "Caddyfile не прошёл проверку"; }

  if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == "Status: active"* ]]; then
    quiet ufw allow 80/tcp
    quiet ufw allow 443/tcp
    ok "ufw: открыты 80/tcp и 443/tcp"
  fi
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  ok "caddy запущен"

  step "Проверка работы"
  wait_ready

  step "Готово"
  "$CLI" _write-links
  chmod 600 /root/webproxy-links.txt
  printf '\n%s╔══════════════════════════════════════════════╗%s\n' "$C_G" "$C_N"
  printf '%s║  WEB-прокси Telegram установлен              ║%s\n' "$C_G" "$C_N"
  printf '%s╚══════════════════════════════════════════════╝%s\n' "$C_G" "$C_N"
  printf '  Домен:     %s\n  Заглушка:  %s (%s)\n\n' "$DOMAIN" "$DECOY" "$(sed -n 1p "$SHARE_DIR/decoys/$DECOY/meta" 2>/dev/null || true)"
  "$CLI" links --qr
  printf '\n  Ссылки сохранены: /root/webproxy-links.txt\n\n'
  printf '%sКоманды:%s\n' "$C_B" "$C_N"
  printf '  webproxy status | links [--qr] | decoy [N] | rotate-secret\n'
  printf '  webproxy restart | logs [telemt|caddy] [-f] | update | uninstall\n\n'
  printf '%s! Звонки через WEB-прокси в Telemt могут не работать. Держите ссылку в секрете.%s\n' "$C_Y" "$C_N"
}

main
exit 0
__PAYLOAD_BELOW__
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
