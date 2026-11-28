#!/usr/bin/env bash
# ------------------------------------------------------------------
# restore.sh — N4: khôi phục CSDL appdb + nội dung web từ bản do backup.sh tạo.
#
# Kiểm tra trước khi đụng vào hệ thống (sai bất kỳ bước nào => dừng, KHÔNG thay đổi gì):
#   1. Tên file đúng mẫu labbackup_YYYYmmdd_HHMMSS.tar.gz và có file .sha256 đi kèm khớp checksum
#   2. Trong archive đúng 4 file: manifest.txt (created_by=backup.sh), SHA256SUMS, db.sql, web.tar
#   3. sha256sum -c SHA256SUMS khớp; db.sql có dòng kết thúc của pg_dump
# Khôi phục:
#   - DB: psql --single-transaction => lỗi giữa chừng thì ROLLBACK, DB giữ nguyên như trước
#   - Web: giải nén vào thư mục tạm rồi rsync --delete vào đúng chỗ
# Kiểm tra sau khôi phục (toàn vẹn):
#   - Số dòng todos == manifest; nội dung todos (sha256 của dữ liệu) == dữ liệu trong db.sql
#   - Checksum từng file web sau khôi phục == trong web.tar
#
# Mã thoát: 0 OK | 1 lỗi | 2 sai tham số | 5 archive không hợp lệ/hỏng
# ------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
usage() {
    cat <<EOF
Cách dùng: sudo ${SCRIPT_NAME} [-f <file>|-r [<tên file>]] [-s all|db|web] [-y] [-l] [-h]

  -f <file>   Khôi phục từ file này (mặc định: bản mới nhất trong BACKUP_DIR)
  -r          Lấy bản từ VM2 (REMOTE_BACKUP_HOST:REMOTE_BACKUP_DIR); kèm tên file ở
              tham số cuối để chọn bản, bỏ trống = bản mới nhất trên VM2
  -s <phần>   all (mặc định) | db | web
  -y          Không hỏi xác nhận (dùng trong script/test)
  -l          Liệt kê các bản backup local (và trên VM2 nếu có -r) rồi thoát
  -h          Trợ giúp (cũng nhận --help)

Ví dụ:
  sudo ${SCRIPT_NAME} -l
  sudo ${SCRIPT_NAME}                       # bản mới nhất local, hỏi xác nhận
  sudo ${SCRIPT_NAME} -f /data/backup/labbackup_20261128_020000.tar.gz -y
  sudo ${SCRIPT_NAME} -r -y                 # bản mới nhất trên backup01
  sudo ${SCRIPT_NAME} -s web -y             # chỉ khôi phục web
EOF
}

case ${1:-} in --help) usage; exit 0;; esac
FILE='' REMOTE=0 SCOPE=all ASSUME_YES=0 LIST=0
while getopts ':hf:rs:yl' opt; do
    case $opt in
        h) usage; exit 0;;
        f) FILE=$OPTARG;;
        r) REMOTE=1;;
        s) SCOPE=$OPTARG;;
        y) ASSUME_YES=1;;
        l) LIST=1;;
        :) printf 'Thiếu giá trị cho -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
        *) printf 'Tuỳ chọn không hợp lệ: -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
    esac
done
shift "$((OPTIND - 1))"
REMOTE_NAME=''
if (( REMOTE )) && (( $# == 1 )); then REMOTE_NAME=$1; shift; fi
if (( $# != 0 )); then usage >&2; exit 2; fi
case $SCOPE in all|db|web) ;; *) printf 'Sai -s: %s\n' "$SCOPE" >&2; usage >&2; exit 2;; esac
if (( REMOTE )) && [[ -n "$FILE" ]]; then printf 'Không dùng -f cùng -r\n' >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Chạy bằng sudo\n' >&2; exit 2; fi

TOOL_NAME=restore
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_root
require_commands runuser psql tar gzip sha256sum find rsync awk sort flock
cd /

: "${BACKUP_DB_NAME:=appdb}"
: "${REMOTE_BACKUP_KEY:=/home/$REMOTE_BACKUP_USER/.ssh/id_ed25519}"
install -d -o root -g root -m 0750 "$LOG_DIR"

NAME_RE='^labbackup_[0-9]{8}_[0-9]{6}\.tar\.gz$'
work=''
cleanup() { [[ -n "$work" ]] && rm -rf -- "$work"; return 0; }
on_error() {
    local code=$1 line=$2
    # Lỗi trong $(...) chạy ở subshell: chỉ thoát subshell, để shell chính báo một lần.
    if [[ $BASHPID != "$$" ]]; then exit "$code"; fi
    trap - ERR
    log_error "Restore THẤT BẠI ở dòng $line (mã $code)"
    send_alert "Restore THẤT BẠI trên $(hostname)" "restore.sh lỗi ở dòng $line (mã $code). Xem $LOG_FILE." || true
    exit "$code"
}
trap 'on_error $? $LINENO' ERR
trap cleanup EXIT
reject() { trap - ERR; log_error "Từ chối: $*"; exit 5; }

ssh_cmd=(ssh -p "$REMOTE_BACKUP_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [[ -r "$REMOTE_BACKUP_KEY" ]]; then ssh_cmd+=(-i "$REMOTE_BACKUP_KEY" -o IdentitiesOnly=yes); fi
remote="$REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST"
remote_dir_q=$(printf '%q' "$REMOTE_BACKUP_DIR")
list_local() { find "$BACKUP_DIR" -maxdepth 1 -type f -name 'labbackup_*.tar.gz' -printf '%f\n' 2>/dev/null | grep -E "$NAME_RE" | sort || true; }
list_remote() { "${ssh_cmd[@]}" "$remote" "ls -1 $remote_dir_q" | grep -E "$NAME_RE" | sort; }

if (( LIST )); then
    printf 'Local (%s):\n' "$BACKUP_DIR"; list_local | sed 's/^/  /'
    if (( REMOTE )); then printf 'VM2 (%s:%s):\n' "$remote" "$REMOTE_BACKUP_DIR"; list_remote | sed 's/^/  /'; fi
    exit 0
fi

install -d -o root -g root -m 0700 "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.backup.lock"   # không restore khi backup đang chạy (và ngược lại)
if ! flock -n 9; then log_error 'Đang có backup/restore khác chạy'; exit 1; fi
work=$(mktemp -d /var/tmp/labrestore.XXXXXX)

# ---------------- 1. Chọn file ----------------
if (( REMOTE )); then
    if [[ -z "$REMOTE_NAME" ]]; then REMOTE_NAME=$(list_remote | tail -n 1); fi
    [[ -n "$REMOTE_NAME" ]] || reject "Không có bản backup nào trên VM2"
    [[ "$REMOTE_NAME" =~ $NAME_RE ]] || reject "Tên không đúng mẫu backup.sh: $REMOTE_NAME"
    log_info "Tải $REMOTE_NAME từ $remote:$REMOTE_BACKUP_DIR"
    install -d -m 0700 "$work/dl"
    rsync -a --timeout=60 -e "${ssh_cmd[*]}" -- \
        "$remote:$REMOTE_BACKUP_DIR/$REMOTE_NAME" "$remote:$REMOTE_BACKUP_DIR/$REMOTE_NAME.sha256" "$work/dl/"
    FILE="$work/dl/$REMOTE_NAME"
elif [[ -z "$FILE" ]]; then
    latest=$(list_local | tail -n 1)
    [[ -n "$latest" ]] || reject "Không có bản backup nào trong $BACKUP_DIR"
    FILE="$BACKUP_DIR/$latest"
fi
[[ -f "$FILE" ]] || reject "Không thấy file: $FILE"
name=$(basename -- "$FILE")
[[ "$name" =~ $NAME_RE ]] || reject "Tên không đúng mẫu backup.sh: $name"

# ---------------- 2. Kiểm tra toàn vẹn TRƯỚC khi khôi phục ----------------
[[ -f "$FILE.sha256" ]] || reject "Thiếu $name.sha256 (không phải bản do backup.sh tạo?)"
expected=$(awk -v n="$name" '$2 == n {print $1}' "$FILE.sha256")
actual=$(sha256sum < "$FILE" | cut -d' ' -f1)
[[ -n "$expected" && "$expected" == "$actual" ]] || reject "Checksum file không khớp: $name bị hỏng hoặc bị sửa"
gzip -t -- "$FILE" 2>/dev/null || reject "File nén hỏng: $name"

members=$(tar -tzf "$FILE" | LC_ALL=C sort | tr '\n' ' ')
[[ "$members" == "SHA256SUMS db.sql manifest.txt web.tar " ]] || reject "Nội dung archive lạ: $members"
install -d -m 0700 "$work/x"
tar -C "$work/x" --no-same-owner -xzf "$FILE"
grep -qx 'created_by=backup.sh' "$work/x/manifest.txt" || reject 'manifest.txt không phải của backup.sh'
(cd "$work/x" && sha256sum --quiet -c SHA256SUMS) || reject 'SHA256SUMS bên trong không khớp'
tail -n 5 "$work/x/db.sql" | grep -q 'PostgreSQL database dump complete' || reject 'db.sql không trọn vẹn'
manifest() { sed -n "s/^$1=//p" "$work/x/manifest.txt"; }
m_db=$(manifest db_name); m_rows=$(manifest todos_rows); m_created=$(manifest created_at)
[[ "$m_db" == "$BACKUP_DB_NAME" ]] || reject "Archive là của DB '$m_db', không phải '$BACKUP_DB_NAME'"
log_info "Archive hợp lệ: $name (tạo lúc $m_created, todos=$m_rows dòng, web: $(manifest web_paths))"

if (( ! ASSUME_YES )); then
    if [[ ! -t 0 ]]; then log_error 'Không có terminal để xác nhận; dùng -y'; exit 2; fi
    read -r -p "Ghi đè $SCOPE bằng $name? Gõ YES để tiếp tục: " answer
    [[ "$answer" == YES ]] || { log_warn 'Người dùng hủy'; exit 1; }
fi

pg() { runuser -u postgres -- env PGOPTIONS='-c TimeZone=UTC' psql -X -q -v ON_ERROR_STOP=1 "$@"; }
dump_todos() { awk '/^COPY public\.todos /{f=1; next} f && /^\\\.$/{exit} f' "$1"; }

# ---------------- 3. Khôi phục DB ----------------
if [[ $SCOPE == all || $SCOPE == db ]]; then
    if [[ $(pg -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$BACKUP_DB_NAME'") != 1 ]]; then
        log_warn "DB $BACKUP_DB_NAME không còn — tạo lại"
        appuser_ok=$(pg -At -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='appuser'")
        [[ "$appuser_ok" == 1 ]] || reject 'Role appuser không tồn tại — chạy configs/postgres/setup-db.sh trước'
        pg -d postgres -c "CREATE DATABASE $BACKUP_DB_NAME OWNER postgres"
        pg -d postgres -c "REVOKE ALL ON DATABASE $BACKUP_DB_NAME FROM PUBLIC; GRANT CONNECT ON DATABASE $BACKUP_DB_NAME TO appuser"
    fi
    # Hai câu riêng: nếu gộp trong CASE, PostgreSQL vẫn phân tích "FROM todos" và lỗi khi bảng đã bị DROP.
    if [[ $(pg -At -d "$BACKUP_DB_NAME" -c "SELECT to_regclass('public.todos') IS NOT NULL") == t ]]; then
        before=$(pg -At -d "$BACKUP_DB_NAME" -c 'SELECT count(*) FROM todos')
    else
        before='không có bảng'
    fi
    log_info "Khôi phục DB $BACKUP_DB_NAME (todos hiện tại: $before → sẽ thành $m_rows)"
    # Một transaction: lỗi ở bất kỳ câu nào => ROLLBACK toàn bộ, DB như trước khi chạy.
    pg --single-transaction -d "$BACKUP_DB_NAME" < "$work/x/db.sql" >/dev/null

    if [[ "$m_rows" != none ]]; then
        rows=$(pg -At -d "$BACKUP_DB_NAME" -c 'SELECT count(*) FROM todos')
        [[ "$rows" == "$m_rows" ]] || { log_error "Số dòng todos sau restore $rows != $m_rows"; exit 1; }
        want=$(dump_todos "$work/x/db.sql" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
        cols=$(awk '/^COPY public\.todos /{sub(/^COPY public\.todos /,""); sub(/ FROM stdin;$/,""); print; exit}' "$work/x/db.sql")
        got=$(pg -At -d "$BACKUP_DB_NAME" -c "COPY public.todos $cols TO STDOUT" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
        [[ "$want" == "$got" ]] || { log_error 'Nội dung todos sau restore khác bản backup'; exit 1; }
        log_info "DB OK: todos $rows dòng, checksum nội dung khớp bản backup"
    fi
    # appuser vẫn phải đọc được (quyền GRANT nằm trong dump)
    perm=$(pg -At -d "$BACKUP_DB_NAME" -c "SELECT has_table_privilege('appuser','public.todos','SELECT,INSERT,UPDATE')" 2>/dev/null || echo f)
    [[ "$m_rows" == none || "$perm" == t ]] || { log_error 'appuser mất quyền trên todos sau restore'; exit 1; }
fi

# ---------------- 4. Khôi phục web ----------------
if [[ $SCOPE == all || $SCOPE == web ]]; then
    install -d -m 0700 "$work/web"
    tar -C "$work/web" --same-owner --numeric-owner -xf "$work/x/web.tar"
    read -r -a paths <<< "$(manifest web_paths)"
    for p in "${paths[@]}"; do
        [[ "$p" == /* && "$p" != *..* ]] || reject "Đường dẫn web lạ trong manifest: $p"
        src="$work/web${p}"
        [[ -d "$src" ]] || reject "web.tar thiếu $p"
        install -d "$p"
        rsync -a --delete -- "$src/" "$p/"
        want=$(cd "$src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum | sha256sum)
        got=$(cd "$p" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum | sha256sum)
        [[ "$want" == "$got" ]] || { log_error "Web $p sau restore khác bản backup"; exit 1; }
        log_info "Web OK: $p ($(find "$p" -type f | wc -l) file, checksum khớp)"
    done
fi

log_info "Khôi phục HOÀN TẤT từ $name (phạm vi: $SCOPE)"
