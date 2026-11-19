#!/usr/bin/env bash
# ------------------------------------------------------------------
# lib.sh — Hàm dùng chung cho bộ công cụ (log, nạp cấu hình, cảnh báo)
# Chủ sở hữu: Người 5. Người khác chỉ `source` file này, không sửa.
# File này được source, không chạy trực tiếp.
# ------------------------------------------------------------------

# Đường dẫn mặc định theo hợp đồng chung (xem KEHOACH.md, Mục 1)
LABTOOLS_CONF="${LABTOOLS_CONF:-/etc/labtools/labtools.conf}"
LOG_DIR="${LOG_DIR:-/var/log/labtools}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/labtools.log}"

# Giá trị mặc định (có thể bị labtools.conf ghi đè)
CPU_THRESHOLD="${CPU_THRESHOLD:-85}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
BACKUP_DIR="${BACKUP_DIR:-/data/backup}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

load_config() {
    if [[ -r "${LABTOOLS_CONF}" ]]; then
        # shellcheck disable=SC1090
        source "${LABTOOLS_CONF}"
    fi
}

_log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    echo "${line}" >&2
    if [[ -d "${LOG_DIR}" && -w "${LOG_DIR}" ]]; then
        echo "${line}" >> "${LOG_FILE}"
    fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# send_alert "Tiêu đề" "Nội dung" — gửi mail qua lệnh mail/msmtp, luôn ghi log
send_alert() {
    local subject="$1" body="$2"
    log_warn "ALERT: ${subject} — ${body}"
    if [[ -z "${ALERT_EMAIL}" ]]; then
        log_warn "ALERT_EMAIL chưa cấu hình, bỏ qua gửi mail"
        return 0
    fi
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "${body}" | mail -s "[labtools] ${subject}" "${ALERT_EMAIL}" \
            || log_error "Gửi mail thất bại"
    else
        log_error "Không có lệnh 'mail', không gửi được cảnh báo"
    fi
}

load_config
