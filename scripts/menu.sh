#!/usr/bin/env bash
# N5: menu tương tác, giữ menu khi công cụ con thất bại.
set -Eeuo pipefail
usage() { printf 'Cách dùng: %s [-h|--help]\n' "${0##*/}"; }
case ${1:-} in -h|--help) usage; exit 0;; esac
if (( $# != 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Dùng sudo\n' >&2; exit 2; fi
TOOL_NAME=menu
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands flock
install -d -o root -g root -m 0750 "$LOG_DIR"
trap 'rc=$?; log_error "Menu lỗi dòng $LINENO (rc=$rc)"; exit "$rc"' ERR

run_tool() {
    local tool=$1 rc
    shift
    if [[ ! -f "$SCRIPT_DIR/$tool" ]]; then
        log_warn "Chưa có $tool: chờ thành viên phụ trách bàn giao"
        return 0
    fi
    # Khởi chạy shell mới; không source công cụ con vào menu.
    if bash "$SCRIPT_DIR/$tool" "$@"; then
        log_info "$tool hoàn tất"
    else
        rc=$?
        log_warn "$tool trả mã $rc; đọc log công cụ rồi chọn tiếp"
    fi
}

while true; do
    printf '\n1. Deploy\n2. Backup\n3. Restore\n4. Healthcheck\n5. Xoay log\n0. Thoát\n'
    if ! read -r -p 'Chọn: ' choice; then log_info 'Hết đầu vào, thoát menu'; break; fi
    case $choice in
        1)
            if ! read -r -p 'Loại (site/nginx/app): ' kind; then break; fi
            if ! read -r -p 'Đường dẫn nguồn: ' source_path; then break; fi
            case $kind in
                site|nginx|app) run_tool deploy.sh -t "$kind" -s "$source_path";;
                *) printf 'Loại deploy không hợp lệ\n';;
            esac
            ;;
        2) run_tool backup.sh;;
        3)
            if [[ ! -f "$SCRIPT_DIR/restore.sh" ]]; then
                log_warn 'Chưa có restore.sh của N4'; continue
            fi
            if ! read -r -p 'File backup cần restore: ' archive; then break; fi
            if [[ ! -f "$archive" ]]; then printf 'File không tồn tại\n'; continue; fi
            if ! read -r -p 'Restore có thể thay dữ liệu hiện tại. Gõ RESTORE để xác nhận: ' answer; then break; fi
            if [[ "$answer" == RESTORE ]]; then run_tool restore.sh -f "$archive"
            else printf 'Đã hủy restore\n'; fi
            ;;
        4) run_tool healthcheck.sh;;
        5) run_tool logrotate.sh;;
        0) log_info 'Người dùng thoát menu'; break;;
        *) printf 'Nhập 0..5; không để trống hoặc nhập chữ.\n';;
    esac
done
