#!/usr/bin/env bash
# N5: thư viện được source. Không ghi đè trap của chương trình gọi.
set -euo pipefail

LABTOOLS_CONF="${LABTOOLS_CONF:-/etc/labtools/labtools.conf}"

load_config() {
    local key value mode
    if [[ ! -f "$LABTOOLS_CONF" || ! -r "$LABTOOLS_CONF" ]]; then
        printf 'Không đọc được cấu hình: %s\n' "$LABTOOLS_CONF" >&2
        return 2
    fi
    mode=$(stat -c '%a' -- "$LABTOOLS_CONF")
    if [[ $(stat -c '%u' -- "$LABTOOLS_CONF") != 0 ]] || (( (8#$mode & 022) != 0 )); then
        printf 'Cấu hình phải thuộc root, không cho group/other ghi\n' >&2
        return 2
    fi
    # shellcheck disable=SC1090
    source "$LABTOOLS_CONF"
    : "${CPU_THRESHOLD:=85}" "${MEM_THRESHOLD:=85}" "${DISK_THRESHOLD:=85}"
    : "${CPU_SAMPLE_SECONDS:=1}" "${DISK_PATHS:=/ /data}" "${REQUIRE_DATA_MOUNT:=1}"
    : "${MONITORED_SERVICES:=nginx labapp postgresql}" "${MONITORED_PORTS:=80 443 5000 5432 2222}"
    : "${CHECK_APP:=1}" "${CHECK_WEB:=1}" "${CHECK_DB:=1}"
    : "${APP_HEALTH_URL:=http://127.0.0.1:5000/health}" "${APP_DOMAIN:=app.lab.local}"
    : "${STATUS_DOMAIN:=status.lab.local}" "${WEB_PORT:=443}" "${WEB_IP:=127.0.0.1}"
    : "${HTTP_TIMEOUT:=5}" "${HTTP_ATTEMPTS:=5}" "${LOG_DIR:=/var/log/labtools}"
    : "${LOG_KEEP:=7}" "${BACKUP_DIR:=/data/backup}" "${BACKUP_RETENTION_DAYS:=7}"
    : "${REMOTE_BACKUP_HOST:=192.168.56.20}" "${REMOTE_BACKUP_USER:=sysadmin}"
    : "${REMOTE_BACKUP_DIR:=/data/backup-recv}" "${REMOTE_BACKUP_PORT:=2222}"
    : "${ALERT_EMAIL:=}" "${LOCAL_ALERT_USER:=sysadmin}" "${SMTP_CONFIG:=/etc/msmtprc}"
    : "${SMTP_ACCOUNT:=default}" "${MAIL_TIMEOUT:=15}" "${STATUS_DIR:=/var/www/status}"
    : "${NGINX_SITE_CONF:=/etc/nginx/sites-available/app.lab.local}"
    : "${DEPLOY_STATE:=/var/lib/labtools/deploy}"
    LOG_FILE="${LOG_FILE:-$LOG_DIR/${TOOL_NAME:-labtools}.log}"
    for key in CPU_THRESHOLD MEM_THRESHOLD DISK_THRESHOLD; do
        value=${!key}
        if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( value > 100 )); then
            printf 'Ngưỡng sai: %s=%s\n' "$key" "$value" >&2; return 2
        fi
    done
    for key in CPU_SAMPLE_SECONDS HTTP_TIMEOUT HTTP_ATTEMPTS LOG_KEEP \
        BACKUP_RETENTION_DAYS MAIL_TIMEOUT WEB_PORT REMOTE_BACKUP_PORT; do
        value=${!key}
        if [[ ! "$value" =~ ^[1-9][0-9]{0,4}$ ]]; then
            printf 'Số nguyên dương không hợp lệ: %s\n' "$key" >&2; return 2
        fi
    done
    for key in CHECK_APP CHECK_WEB CHECK_DB REQUIRE_DATA_MOUNT; do
        if [[ ${!key} != 0 && ${!key} != 1 ]]; then
            printf '%s phải là 0 hoặc 1\n' "$key" >&2; return 2
        fi
    done
    if [[ "$LOG_DIR" != /var/log/labtools || "$DEPLOY_STATE" != /var/lib/labtools/deploy ]]; then
        printf 'Giữ LOG_DIR và DEPLOY_STATE theo hợp đồng\n' >&2; return 2
    fi
    if (( WEB_PORT > 65535 || REMOTE_BACKUP_PORT > 65535 )); then
        printf 'Cổng vượt 65535\n' >&2; return 2
    fi
}

require_root() {
    if (( EUID != 0 )); then printf 'Chạy công cụ bằng sudo\n' >&2; return 2; fi
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'Thiếu lệnh: %s\n' "$command_name" >&2; return 2
        fi
    done
}

_log() {
    local level=$1 line log_fd
    shift
    line="$(date '+%F %T') [$level] [${TOOL_NAME:-labtools}] $*"
    printf '%s\n' "$line" >&2
    # Từng lần ghi dùng cùng khóa với logrotate, không giữ file mở lâu.
    exec {log_fd}>>"$LOG_FILE.lock"
    flock -x "$log_fd"
    printf '%s\n' "$line" >> "$LOG_FILE"
    flock -u "$log_fd"
    exec {log_fd}>&-
}
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

send_alert() {
    local subject=$1 body=$2
    subject=${subject//$'\n'/ }
    subject=${subject//$'\r'/ }
    log_warn "ALERT: $subject"
    if [[ -n "$ALERT_EMAIL" && "$ALERT_EMAIL" != THAY_* && -r "$SMTP_CONFIG" ]] \
        && command -v msmtp >/dev/null 2>&1; then
        if printf 'To: %s\nSubject: [labtools] %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
            "$ALERT_EMAIL" "$subject" "$body" \
            | timeout "${MAIL_TIMEOUT}s" msmtp --file="$SMTP_CONFIG" \
                --account="$SMTP_ACCOUNT" -- "$ALERT_EMAIL"; then
            log_info 'SMTP đã chấp nhận thư; kiểm tra hộp thư nhận'
            return 0
        fi
        log_warn 'SMTP thất bại, chuyển sang mail local'
    else
        log_warn 'SMTP chưa sẵn sàng, thử mail local'
    fi
    if command -v mail >/dev/null 2>&1; then
        if printf '%s\n' "$body" | MAILRC=/dev/null timeout "${MAIL_TIMEOUT}s" \
            mail -s "[labtools] $subject" -- "$LOCAL_ALERT_USER"; then
            log_info "Đã nộp thư cho MTA local: $LOCAL_ALERT_USER"
            return 0
        fi
    fi
    log_error 'Cả hai đường cảnh báo đều không gửi được'
    return 1
}

# Chỉ chấp nhận HTTP 200; --resolve giữ đúng Host/SNI mà không cần DNS.
# -k chỉ dùng cho cert tự ký của lab, không phải mặc định cho môi trường thật.
http_ok() {
    local code
    if ! code=$(curl --noproxy '*' -ksS --max-time "$HTTP_TIMEOUT" \
        --resolve "$APP_DOMAIN:$WEB_PORT:$WEB_IP" \
        --resolve "$STATUS_DOMAIN:$WEB_PORT:$WEB_IP" \
        -o /dev/null -w '%{http_code}' "$1"); then return 1; fi
    [[ "$code" == 200 ]]
}

wait_http() {
    local attempt
    for (( attempt=1; attempt<=HTTP_ATTEMPTS; attempt++ )); do
        if http_ok "$1"; then return 0; fi
        sleep 1
    done
    return 1
}

load_config
