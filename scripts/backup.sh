#!/usr/bin/env bash
# ------------------------------------------------------------------
# backup.sh — N4: sao lưu CSDL appdb + nội dung web thành
#   $BACKUP_DIR/labbackup_YYYYmmdd_HHMMSS.tar.gz  (chứa db.sql, web.tar, manifest.txt, SHA256SUMS)
#   $BACKUP_DIR/labbackup_YYYYmmdd_HHMMSS.tar.gz.sha256  (checksum cả file, dùng khi restore/rsync)
# rồi xóa bản cũ hơn BACKUP_RETENTION_DAYS ngày và rsync sang VM2 (backup01).
#
# An toàn:
#   - Kiểm tra dung lượng TRƯỚC khi chạy: thiếu chỗ thì cảnh báo, thoát mã 4, không tạo file nào.
#   - Mọi thứ được tạo trong file tạm (.part / .work.*); chỉ đổi tên thành bản chính thức khi
#     đã dump + nén + kiểm tra xong. Lỗi giữa chừng => trap xóa file dở + gửi cảnh báo.
#   - set -o pipefail: "tar ... | gzip" mà tar lỗi thì cả lệnh lỗi, không ra file .gz rỗng.
#
# Mã thoát: 0 OK | 1 lỗi | 2 sai tham số/cấu hình | 3 backup local OK nhưng rsync lỗi | 4 thiếu dung lượng
# Cấu hình: /etc/labtools/labtools.conf (BACKUP_DIR, BACKUP_RETENTION_DAYS, REMOTE_BACKUP_*, ...)
# ------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
usage() {
    cat <<EOF
Cách dùng: sudo ${SCRIPT_NAME} [-n] [-h]

  -n    Chỉ backup local, không rsync sang VM2
  -h    Hiển thị trợ giúp (cũng nhận --help)

Tạo labbackup_YYYYmmdd_HHMMSS.tar.gz trong BACKUP_DIR, xóa bản cũ hơn
BACKUP_RETENTION_DAYS ngày, rồi rsync sang REMOTE_BACKUP_USER@REMOTE_BACKUP_HOST:REMOTE_BACKUP_DIR.
Mã thoát: 0 OK, 1 lỗi, 2 sai tham số, 3 rsync lỗi (bản local vẫn tốt), 4 thiếu dung lượng.
EOF
}

case ${1:-} in --help) usage; exit 0;; esac
NO_REMOTE=0
while getopts ':hn' opt; do
    case $opt in
        h) usage; exit 0;;
        n) NO_REMOTE=1;;
        *) printf 'Tuỳ chọn không hợp lệ: -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
    esac
done
shift "$((OPTIND - 1))"
if (( $# != 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Chạy bằng sudo\n' >&2; exit 2; fi

TOOL_NAME=backup
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands runuser pg_dump psql tar gzip sha256sum df du find flock mountpoint awk
cd /   # runuser -u postgres cần thư mục hiện tại đọc được

# Giá trị riêng của N4 (có thể đặt trong labtools.conf).
: "${BACKUP_DB_NAME:=appdb}"
: "${BACKUP_WEB_PATHS:=$STATUS_DIR /opt/app/public}"
: "${BACKUP_RESERVE_MB:=100}"
: "${REMOTE_BACKUP_ENABLED:=1}"
: "${REMOTE_BACKUP_KEY:=/home/$REMOTE_BACKUP_USER/.ssh/id_ed25519}"

install -d -o root -g root -m 0750 "$LOG_DIR"

if [[ ! "$BACKUP_DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then log_error "BACKUP_DB_NAME sai: $BACKUP_DB_NAME"; exit 2; fi
if [[ ! "$BACKUP_RESERVE_MB" =~ ^[0-9]{1,6}$ ]]; then log_error "BACKUP_RESERVE_MB sai: $BACKUP_RESERVE_MB"; exit 2; fi
if [[ "$BACKUP_DIR" != /* || "$BACKUP_DIR" == / ]]; then log_error "BACKUP_DIR phải là đường dẫn tuyệt đối: $BACKUP_DIR"; exit 2; fi

work='' part='' sidecar_part=''
cleanup() {
    # Chạy ở mọi lối thoát: không để lại file dở dang.
    [[ -n "$work" ]] && rm -rf -- "$work"
    [[ -n "$part" ]] && rm -f -- "$part"
    [[ -n "$sidecar_part" ]] && rm -f -- "$sidecar_part"
    return 0
}
on_error() {
    local code=$1 line=$2
    # Lỗi trong $(...) chạy ở subshell: chỉ thoát subshell, để shell chính báo một lần.
    if [[ $BASHPID != "$$" ]]; then exit "$code"; fi
    trap - ERR
    log_error "Backup THẤT BẠI ở dòng $line (mã $code); đã xóa file dở"
    send_alert "Backup THẤT BẠI trên $(hostname)" \
        "backup.sh lỗi ở dòng $line (mã $code). Xem $LOG_FILE. Không có bản backup mới." || true
    exit "$code"
}
trap 'on_error $? $LINENO' ERR
trap cleanup EXIT

fail() {   # fail <mã> <tin nhắn>: lỗi có chủ đích, có cảnh báo
    local code=$1; shift
    trap - ERR
    log_error "$*"
    send_alert "Backup THẤT BẠI trên $(hostname)" "$*" || true
    exit "$code"
}

# /data phải là phân vùng riêng; nếu đĩa phụ chưa mount thì backup sẽ rơi vào ổ / => từ chối.
if (( REQUIRE_DATA_MOUNT )) && [[ "$BACKUP_DIR" == /data/* ]] && ! mountpoint -q /data; then
    fail 1 '/data chưa được mount (kiểm tra /etc/fstab) — không backup vào ổ hệ thống'
fi

install -d -o root -g root -m 0700 "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.backup.lock"
if ! flock -n 9; then log_error 'Đang có một backup khác chạy'; exit 1; fi

# Đang giữ khóa => mọi file tạm còn sót là của lần chạy trước bị ngắt (kill -9, mất điện): dọn.
find "$BACKUP_DIR" -maxdepth 1 \( -name '.labbackup_*.part' -o -name '.work.*' \) -exec rm -rf -- {} +

pgq() { runuser -u postgres -- psql -X -At -v ON_ERROR_STOP=1 -d "$BACKUP_DB_NAME" "$@"; }

# ---------------- 1. Kiểm tra dung lượng (câu "2 giờ sáng đĩa đầy thì sao") ----------------
read -r -a web_paths <<< "$BACKUP_WEB_PATHS"
existing_web=()
for p in "${web_paths[@]}"; do
    if [[ "$p" != /* ]]; then fail 2 "Đường dẫn web phải tuyệt đối: $p"; fi
    if [[ -e "$p" ]]; then existing_web+=("${p#/}"); else log_warn "Bỏ qua (không tồn tại): $p"; fi
done

db_bytes=$(pgq -c "SELECT pg_database_size(current_database())")
web_bytes=0
if (( ${#existing_web[@]} )); then
    web_bytes=$(cd / && du -scb -- "${existing_web[@]}" | tail -n 1 | cut -f1)
fi
# x2: bản chưa nén trong .work + file nén; cộng thêm phần chừa trống cho hệ thống.
need=$(( (db_bytes + web_bytes) * 2 + BACKUP_RESERVE_MB * 1024 * 1024 ))
avail=$(df -B1 --output=avail -- "$BACKUP_DIR" | tail -n 1 | tr -d ' ')
log_info "Dung lượng: cần ~$(( need / 1048576 )) MiB, còn $(( avail / 1048576 )) MiB trên $BACKUP_DIR"
if (( avail < need )); then
    fail 4 "Không đủ dung lượng trên $BACKUP_DIR: còn $(( avail / 1048576 )) MiB, cần ~$(( need / 1048576 )) MiB. Không chạy backup."
fi

# ---------------- 2. Dump + gói web vào thư mục tạm ----------------
ts=$(date '+%Y%m%d_%H%M%S')
name="labbackup_${ts}.tar.gz"
final="$BACKUP_DIR/$name"
if [[ -e "$final" ]]; then fail 1 "Đã có $final (chạy 2 lần trong cùng 1 giây?)"; fi
work=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
part="$BACKUP_DIR/.${name}.part"
sidecar_part="$BACKUP_DIR/.${name}.sha256.part"

log_info "Dump CSDL $BACKUP_DB_NAME"
# --clean --if-exists: khi restore sẽ DROP rồi tạo lại => khôi phục được cả khi bảng đã bị DROP.
runuser -u postgres -- env PGOPTIONS='-c TimeZone=UTC' \
    pg_dump --no-password --clean --if-exists -d "$BACKUP_DB_NAME" > "$work/db.sql"
# pg_dump chỉ ghi dòng này khi dump trọn vẹn: chặn trường hợp file bị cắt ngang.
if ! tail -n 5 "$work/db.sql" | grep -q 'PostgreSQL database dump complete'; then
    fail 1 'db.sql không trọn vẹn (thiếu dòng kết thúc của pg_dump)'
fi
todos_rows=$(awk '/^COPY public\.todos /{f=1; found=1; next} f && /^\\\.$/{exit} f{n++} END{print found ? n+0 : "none"}' "$work/db.sql")
log_info "db.sql: $(du -h "$work/db.sql" | cut -f1), bảng todos: $todos_rows dòng"

log_info "Gói web: ${BACKUP_WEB_PATHS}"
if (( ${#existing_web[@]} )); then
    tar -C / --numeric-owner -cf "$work/web.tar" -- "${existing_web[@]}"
else
    tar -cf "$work/web.tar" --files-from /dev/null
fi

{
    printf 'created_by=backup.sh\n'
    printf 'format=1\n'
    printf 'created_at=%s\n' "$(date -Is)"
    printf 'host=%s\n' "$(hostname)"
    printf 'db_name=%s\n' "$BACKUP_DB_NAME"
    printf 'todos_rows=%s\n' "$todos_rows"
    printf 'web_paths=%s\n' "${existing_web[*]/#//}"
} > "$work/manifest.txt"
(cd "$work" && sha256sum db.sql web.tar manifest.txt > SHA256SUMS)

# ---------------- 3. Nén (pipefail bảo vệ đường ống này) ----------------
tar -C "$work" -cf - manifest.txt SHA256SUMS db.sql web.tar | gzip -6 > "$part"
gzip -t "$part"
chmod 0600 "$part"
printf '%s  %s\n' "$(sha256sum < "$part" | cut -d' ' -f1)" "$name" > "$sidecar_part"
chmod 0600 "$sidecar_part"
# Đổi tên là thao tác nguyên tử: hoặc có bản đầy đủ, hoặc không có gì.
mv -f -- "$sidecar_part" "$final.sha256"; sidecar_part=''
mv -f -- "$part" "$final"; part=''
rm -rf -- "$work"; work=''
log_info "Đã tạo $final ($(du -h "$final" | cut -f1))"

# ---------------- 4. Retention: xóa bản cũ hơn N ngày ----------------
deleted=0
while IFS= read -r -d '' old; do
    rm -f -- "$old" "$old.sha256"
    log_info "Retention: đã xóa $(basename "$old")"
    deleted=$((deleted + 1))
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'labbackup_*.tar.gz' \
            -mmin +"$(( BACKUP_RETENTION_DAYS * 1440 ))" ! -path "$final" -print0)
# Sidecar mồ côi (bản chính đã mất)
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'labbackup_*.tar.gz.sha256' \
    -mmin +"$(( BACKUP_RETENTION_DAYS * 1440 ))" -delete
log_info "Retention ${BACKUP_RETENTION_DAYS} ngày: xóa $deleted bản cũ"

# ---------------- 5. Rsync sang VM2 ----------------
if (( NO_REMOTE )) || (( ! REMOTE_BACKUP_ENABLED )); then
    log_info 'Bỏ qua rsync (tắt bằng -n hoặc REMOTE_BACKUP_ENABLED=0)'
    log_info 'Backup hoàn tất'
    exit 0
fi
require_commands rsync ssh
ssh_cmd=(ssh -p "$REMOTE_BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [[ -r "$REMOTE_BACKUP_KEY" ]]; then ssh_cmd+=(-i "$REMOTE_BACKUP_KEY" -o IdentitiesOnly=yes); fi
remote="$REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST"
remote_dir_q=$(printf '%q' "$REMOTE_BACKUP_DIR")
log_info "Rsync sang $remote:$REMOTE_BACKUP_DIR"
if rsync -a --timeout=60 -e "${ssh_cmd[*]}" -- "$final.sha256" "$final" "$remote:$REMOTE_BACKUP_DIR/" \
    && "${ssh_cmd[@]}" "$remote" "cd $remote_dir_q && sha256sum --quiet -c $name.sha256"; then
    log_info "Rsync OK, checksum trên VM2 khớp: $REMOTE_BACKUP_DIR/$name"
else
    trap - ERR
    log_error "Rsync sang $remote THẤT BẠI — bản local $final vẫn dùng được"
    send_alert "Backup: rsync sang VM2 thất bại ($(hostname))" \
        "Bản backup local $final đã tạo xong nhưng không gửi được sang $remote:$REMOTE_BACKUP_DIR." || true
    exit 3
fi
log_info 'Backup hoàn tất'
