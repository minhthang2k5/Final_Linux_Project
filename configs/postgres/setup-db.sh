#!/usr/bin/env bash
# ------------------------------------------------------------------
# setup-db.sh — N4: cài cấu hình PostgreSQL, tạo DB appdb + role appuser (quyền tối thiểu),
# tạo bảng todos và (tuỳ chọn) dữ liệu mẫu. Chạy lại nhiều lần không lỗi.
# Mật khẩu appuser lấy từ biến môi trường DB_PASSWORD hoặc từ /etc/labapp/app.env
# (không bao giờ ghi mật khẩu trong repo hay trên dòng lệnh).
# ------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=/etc/labapp/app.env
DB_NAME=appdb
DB_USER=appuser
SAMPLE=0

usage() {
    cat <<EOF
Cách dùng: sudo ${SCRIPT_NAME} [-s] [-e <file env>]

  -s    Thêm dữ liệu mẫu vào todos (chỉ khi bảng đang rỗng)
  -e    File chứa DB_PASSWORD (mặc định: ${ENV_FILE})
  -h    Trợ giúp

Mật khẩu: ưu tiên biến môi trường DB_PASSWORD, sau đó dòng DB_PASSWORD=... trong file env.
Ví dụ:  sudo ${SCRIPT_NAME} -s
EOF
}

log() { printf '%s [setup-db] %s\n' "$(date '+%F %T')" "$*" >&2; }
on_error() { local line=$1 code=$2; log "LỖI ở dòng $line (mã $code)"; exit "$code"; }
trap 'on_error $LINENO $?' ERR

case ${1:-} in --help) usage; exit 0;; *) ;; esac
while getopts ':hse:' opt; do
    case $opt in
        h) usage; exit 0;;
        s) SAMPLE=1;;
        e) ENV_FILE=$OPTARG;;
        :) printf 'Thiếu giá trị cho -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
        *) printf 'Tuỳ chọn không hợp lệ: -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
    esac
done
shift "$((OPTIND - 1))"
if (( $# != 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Chạy bằng sudo\n' >&2; exit 2; fi
for c in psql pg_ctlcluster runuser ss; do
    command -v "$c" >/dev/null 2>&1 || { printf 'Thiếu lệnh: %s (apt install postgresql)\n' "$c" >&2; exit 2; }
done
cd /   # tránh cảnh báo "could not change directory" khi chạy bằng user postgres

# ---- Lấy mật khẩu (không in ra, không đưa lên dòng lệnh) ----
password=${DB_PASSWORD:-}
if [[ -z "$password" && -r "$ENV_FILE" ]]; then
    password=$(sed -n 's/^[[:space:]]*DB_PASSWORD=//p' "$ENV_FILE" | tail -n 1)
    password=${password%$'\r'}
    # Bỏ cặp nháy bao quanh nếu có: DB_PASSWORD="..." hoặc '...'
    if [[ "$password" =~ ^\"(.*)\"$ || "$password" =~ ^\'(.*)\'$ ]]; then password=${BASH_REMATCH[1]}; fi
fi
if [[ -z "$password" ]]; then
    log "Không có DB_PASSWORD (biến môi trường hoặc $ENV_FILE)"; exit 2
fi
if (( ${#password} < 8 )); then log 'DB_PASSWORD quá ngắn (tối thiểu 8 ký tự)'; exit 2; fi

# ---- Cấu hình cluster ----
mapfile -t versions < <(find /etc/postgresql -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V)
if (( ${#versions[@]} == 0 )); then log 'Chưa cài PostgreSQL (/etc/postgresql trống)'; exit 2; fi
ver=${versions[-1]}
conf_dir=/etc/postgresql/$ver/main
log "PostgreSQL $ver, cấu hình ở $conf_dir"

install -d -o postgres -g postgres -m 0755 "$conf_dir/conf.d"
install -o postgres -g postgres -m 0644 "$SCRIPT_DIR/99-lab.conf" "$conf_dir/conf.d/99-lab.conf"
if [[ ! -e "$conf_dir/pg_hba.conf.orig" ]]; then
    cp -p "$conf_dir/pg_hba.conf" "$conf_dir/pg_hba.conf.orig"
    log "Đã lưu bản gốc: $conf_dir/pg_hba.conf.orig"
fi
install -o postgres -g postgres -m 0640 "$SCRIPT_DIR/pg_hba.conf" "$conf_dir/pg_hba.conf"
pg_ctlcluster "$ver" main restart
log 'Đã khởi động lại cluster với cấu hình mới'

pg() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# Escape cho \set của psql: trong nháy đơn, '' = ' và \\ = \
pw_escaped=${password//\\/\\\\}
pw_escaped=${pw_escaped//\'/\'\'}

# Mật khẩu đi qua stdin, không xuất hiện trong ps/cmdline.
pg -d postgres <<SQL
\\set pw '${pw_escaped}'
SELECT 'CREATE ROLE ${DB_USER} LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}')\\gexec
ALTER ROLE ${DB_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 20 PASSWORD :'pw';
SELECT 'CREATE DATABASE ${DB_NAME} OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\\gexec
REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};
SQL
log "Role $DB_USER và DB $DB_NAME đã sẵn sàng"

pg -d "$DB_NAME" < "$SCRIPT_DIR/schema.sql"
log 'Đã áp dụng schema.sql (bảng todos + quyền)'
if (( SAMPLE )); then
    pg -d "$DB_NAME" < "$SCRIPT_DIR/sample-data.sql"
    log 'Đã thêm dữ liệu mẫu (nếu bảng rỗng)'
fi

# ---- Tự kiểm tra ----
flags=$(pg -d postgres -Atc "SELECT rolsuper||','||rolcreatedb||','||rolcreaterole FROM pg_roles WHERE rolname='${DB_USER}'")
if [[ "$flags" != "false,false,false" ]]; then log "appuser có quyền thừa: $flags"; exit 1; fi
rows=$(pg -d "$DB_NAME" -Atc 'SELECT count(*) FROM todos')
log "Kiểm tra: appuser không superuser/createdb/createrole; todos có $rows dòng"
log 'Cổng 5432 đang nghe:'
ss -Htln 'sport = :5432' >&2
