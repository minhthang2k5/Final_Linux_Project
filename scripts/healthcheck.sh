#!/usr/bin/env bash
# N5: kiểm tra tài nguyên, cổng, dịch vụ, HTTP; tổng hợp một cảnh báo/lần chạy.
set -Eeuo pipefail
usage() { printf 'Cách dùng: %s [-h|--help]\nCấu hình chọn bằng LABTOOLS_CONF.\n' "${0##*/}"; }
case ${1:-} in -h|--help) usage; exit 0;; esac
if (( $# != 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Dùng sudo\n' >&2; exit 2; fi
TOOL_NAME=healthcheck
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands awk df ss findmnt systemctl flock curl
if (( CHECK_DB )); then require_commands pg_isready; fi
install -d -o root -g root -m 0750 "$LOG_DIR"
on_error() {
    local rc=$1 line=$2
    log_error "Lỗi không dự kiến ở dòng $line (rc=$rc)"
    exit "$rc"
}
trap 'on_error "$?" "$LINENO"' ERR

issues=()
issue() { issues+=("$*"); log_warn "$*"; }
cpu_counters() {
    awk '/^cpu / {total=0; for(i=2;i<=9;i++) total+=$i; print total, $5+$6; exit}' /proc/stat
}
read -r total_before idle_before < <(cpu_counters)
sleep "$CPU_SAMPLE_SECONDS"
read -r total_after idle_after < <(cpu_counters)
delta=$((total_after - total_before))
if (( delta > 0 )); then
    cpu=$((100 * (delta - idle_after + idle_before) / delta))
    log_info "CPU=${cpu}% (mẫu ${CPU_SAMPLE_SECONDS}s)"
    if (( cpu > CPU_THRESHOLD )); then issue "CPU $cpu% > $CPU_THRESHOLD%"; fi
else
    issue 'Không tính được CPU: khoảng lấy mẫu không hợp lệ'
fi
mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if(t>0) printf "%.0f",100*(t-a)/t; else exit 1}' /proc/meminfo)
log_info "RAM=${mem}%"
if (( mem > MEM_THRESHOLD )); then issue "RAM $mem% > $MEM_THRESHOLD%"; fi

if (( REQUIRE_DATA_MOUNT )) && ! findmnt --mountpoint /data >/dev/null; then
    issue '/data chưa được mount: thư mục thường không thay thế phân vùng backup'
fi
read -r -a disks <<< "$DISK_PATHS"
for disk in "${disks[@]}"; do
    if [[ ! -d "$disk" ]]; then issue "Không có đường dẫn disk: $disk"; continue; fi
    if [[ "$disk" == /data ]] && ! findmnt --mountpoint /data >/dev/null; then
        issue 'Bỏ qua số liệu /data vì chưa có mount riêng'
        continue
    fi
    if used=$(df --output=pcent -- "$disk" | awk 'NR==2 {gsub(/[% ]/, ""); print}'); then
        log_info "Disk $disk=${used}%"
        if (( used > DISK_THRESHOLD )); then issue "Disk $disk $used% > $DISK_THRESHOLD%"; fi
    else
        issue "Không đo được dung lượng $disk"
    fi
done

read -r -a services <<< "$MONITORED_SERVICES"
for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then log_info "Service $service active"
    else issue "Service $service không active"; fi
done
read -r -a ports <<< "$MONITORED_PORTS"
for port in "${ports[@]}"; do
    if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        log_error "Cổng cấu hình sai: $port"; exit 2
    fi
    if listeners=$(ss -H -ltn "sport = :$port"); then
        if [[ -n "$listeners" ]]; then log_info "TCP $port đang lắng nghe"
        else issue "TCP $port không lắng nghe"; fi
    else issue "Không kiểm tra được TCP $port"; fi
done
if (( CHECK_DB )); then
    if pg_isready -q -h 127.0.0.1 -p 5432 -t 3; then log_info 'PostgreSQL nhận kết nối'
    else issue 'PostgreSQL không nhận kết nối tại 127.0.0.1:5432'; fi
fi
if (( CHECK_APP )); then
    if http_ok "$APP_HEALTH_URL"; then log_info 'App /health HTTP 200'
    else issue 'App /health không trả HTTP 200'; fi
fi
if (( CHECK_WEB )); then
    if http_ok "https://$STATUS_DOMAIN:$WEB_PORT/"; then log_info 'Status HTTPS 200'
    else issue 'Status HTTPS không trả HTTP 200'; fi
    if (( CHECK_APP )); then
        if http_ok "https://$APP_DOMAIN:$WEB_PORT/health"; then log_info 'App qua Nginx HTTPS 200'
        else issue 'App qua Nginx HTTPS không trả HTTP 200'; fi
    fi
fi
if (( ${#issues[@]} > 0 )); then
    body=$(printf '%s\n' "${issues[@]}")
    if ! send_alert "Healthcheck $(hostname): ${#issues[@]} bất thường" "$body"; then
        log_error 'Healthcheck lỗi và cảnh báo cũng thất bại'
    fi
    exit 1
fi
log_info 'PASS: tất cả kiểm tra đã cấu hình đều đạt'
