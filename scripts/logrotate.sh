#!/usr/bin/env bash
# N5: xoay log của labtools, nén và giữ N thế hệ; phối hợp khóa với lib.sh.
set -Eeuo pipefail
usage() { printf 'Cách dùng: %s [-f /var/log/labtools/file.log] [-n N] [-h|--help]\n' "${0##*/}"; }
case ${1:-} in -h|--help) usage; exit 0;; esac
file='' keep=''
while getopts ':hf:n:' opt; do
    case $opt in h) usage; exit 0;; f) file=$OPTARG;; n) keep=$OPTARG;; *) usage >&2; exit 2;; esac
done
shift "$((OPTIND - 1))"
if (( $# != 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Dùng sudo\n' >&2; exit 2; fi
TOOL_NAME=logrotate
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands flock gzip realpath stat
install -d -o root -g root -m 0750 "$LOG_DIR"
file=${file:-$LOG_DIR/healthcheck.log}
keep=${keep:-$LOG_KEEP}
if [[ ! "$keep" =~ ^[1-9][0-9]{0,2}$ ]]; then log_error 'N phải trong 1..999'; exit 2; fi
if [[ ! -f "$file" || -L "$file" ]]; then log_error 'Cần một file log thường đã tồn tại'; exit 2; fi
file=$(realpath -e -- "$file")
if [[ "$file" != "$LOG_DIR/"*.log || "$file" == "$LOG_FILE" ]]; then
    log_error 'Chỉ xoay log labtools và không xoay log của chính lần logrotate này'; exit 2
fi
temp=
finish() {
    local rc=$?
    trap - EXIT
    if [[ -n "$temp" && -f "$temp" ]]; then rm -f -- "$temp"; fi
    exit "$rc"
}
trap 'rc=$?; log_error "Xoay log lỗi dòng $LINENO (rc=$rc)"; exit "$rc"' ERR
trap finish EXIT
exec 9>>"$file.lock"
flock -x 9
temp=$(mktemp "$LOG_DIR/.rotate.XXXXXX")
gzip -c -- "$file" > "$temp"
chmod "$(stat -c '%a' -- "$file")" "$temp"
chown --reference="$file" "$temp"

# Chỉ xóa file đúng mẫu file.log.<số>.gz, không quét xóa cả thư mục.
shopt -s nullglob
for archive in "$file".*.gz; do
    number=${archive#"$file".}
    number=${number%.gz}
    if [[ "$number" =~ ^[1-9][0-9]{0,2}$ ]] && (( number >= keep )); then
        rm -- "$archive"
    fi
done
for (( generation=keep-1; generation>=1; generation-- )); do
    if [[ -f "$file.$generation.gz" ]]; then
        mv -- "$file.$generation.gz" "$file.$((generation+1)).gz"
    fi
done
mv -- "$temp" "$file.1.gz"
temp=
: > "$file"
flock -u 9
log_info "Đã xoay $file, giữ tối đa $keep thế hệ"
