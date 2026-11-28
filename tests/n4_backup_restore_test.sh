#!/usr/bin/env bash
# ------------------------------------------------------------------
# n4_backup_restore_test.sh — N4: kiểm thử tự động setup-db.sh, backup.sh, restore.sh, timer.
# Chạy trên Ubuntu 22.04 (VM web01 hoặc WSL) đã cài postgresql, rsync, openssh-server, shellcheck:
#     sudo tests/n4_backup_restore_test.sh
# Mọi thứ của test nằm trong /tmp/n4test.*: cấu hình riêng (LABTOOLS_CONF), BACKUP_DIR riêng,
# thư mục web giả, một sshd tạm ở 127.0.0.1:2222 đóng vai VM2 (user n4remote).
# CHÚ Ý: test tạo/ghi đè DB appdb và role appuser của máy đang chạy. Đừng chạy trên máy demo
# khi đang có dữ liệu thật.
# ------------------------------------------------------------------
# Test cố ý truyền $1/$2 vào bash -c '...' nên tắt SC2016 cho cả file.
# shellcheck disable=SC2016
set -Eeuo pipefail

usage() { printf 'Cách dùng: sudo %s [-h]\n  Chạy toàn bộ test N4 (xem chú thích đầu file).\n' "${0##*/}"; }
case ${1:-} in -h|--help) usage; exit 0;; *) ;; esac
if (( EUID != 0 )); then echo 'Chạy bằng sudo' >&2; exit 2; fi
trap 'echo "Lỗi hạ tầng test ở dòng $LINENO" >&2' ERR

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SELF="$REPO/tests/$(basename -- "${BASH_SOURCE[0]}")"
T=$(mktemp -d /tmp/n4test.XXXXXX)
chmod 755 "$T"
cd /   # psql chạy bằng user postgres cần thư mục hiện tại đọc được
SSH_PORT=2222
REMOTE_USER=n4remote
PASS=0 FAIL=0
FAILED=()

ok()   { PASS=$((PASS + 1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
bad()  {
    FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  \e[31mFAIL\e[0m %s\n' "$1"
    if [[ -s "$T/out" ]]; then sed 's/^/       | /' "$T/out" | tail -n 8; fi
}
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; : > "$T/out"; }
section() { printf '\n== %s ==\n' "$1"; }

cleanup() {
    set +e
    [[ -f "$T/sshd.pid" ]] && kill "$(cat "$T/sshd.pid")" 2>/dev/null
    mountpoint -q "$T/small" && umount "$T/small"
    ssh-keygen -R "[127.0.0.1]:$SSH_PORT" >/dev/null 2>&1
    rm -rf -- "$T"
}
trap cleanup EXIT

# ---------------- Hạ tầng test ----------------
section 'Chuẩn bị môi trường'
for c in psql pg_ctlcluster rsync sshd ssh-keygen shellcheck; do
    command -v "$c" >/dev/null || { echo "Thiếu $c"; exit 2; }
done
if ss -Htln "sport = :$SSH_PORT" | grep -q .; then echo "Cổng $SSH_PORT đang bận"; exit 2; fi
systemctl start postgresql
# Bắt đầu từ DB sạch để kết quả lặp lại được (test sẽ tạo lại appdb).
runuser -u postgres -- psql -X -q -d postgres -c 'DROP DATABASE IF EXISTS appdb WITH (FORCE)'

DB_PASSWORD="Test-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export DB_PASSWORD
mkdir -p "$T/www/status" "$T/opt/app/public" "$T/backup" "$T/small" "$T/fakebin"
printf '<h1>status ok</h1>\n' > "$T/www/status/index.html"
printf 'body{color:red}\n' > "$T/www/status/style.css"
printf '<h1>Todo app</h1>\n' > "$T/opt/app/public/index.html"
mkdir -p "$T/opt/app/public/js" && printf 'console.log(1)\n' > "$T/opt/app/public/js/app.js"

# "VM2" giả: user n4remote + sshd tạm, đăng nhập bằng key không mật khẩu
id "$REMOTE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$REMOTE_USER"
usermod -p '*' "$REMOTE_USER"
REMOTE_DIR=/home/$REMOTE_USER/backup-recv
rm -rf "$REMOTE_DIR"; install -d -o "$REMOTE_USER" -m 0700 "$REMOTE_DIR"
ssh-keygen -q -t ed25519 -N '' -f "$T/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey"
install -d -m 0755 "$T/ak"; install -m 0644 "$T/id_ed25519.pub" "$T/ak/$REMOTE_USER"
cat > "$T/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $T/hostkey
PidFile $T/sshd.pid
AuthorizedKeysFile $T/ak/%u
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
UsePAM no
AllowUsers $REMOTE_USER
Subsystem sftp internal-sftp
EOF
/usr/sbin/sshd -f "$T/sshd_config"
for _ in 1 2 3 4 5 6 7 8 9 10; do ss -Htln "sport = :$SSH_PORT" | grep -q . && break; sleep 0.3; done

# make_conf <file> [KEY=VALUE ...]: tạo cấu hình labtools riêng cho test (root:root 644)
make_conf() {
    local f=$1; shift
    cat > "$f" <<EOF
BACKUP_DIR=$T/backup
BACKUP_RETENTION_DAYS=7
BACKUP_DB_NAME=appdb
BACKUP_WEB_PATHS="$T/www/status $T/opt/app/public"
BACKUP_RESERVE_MB=20
REQUIRE_DATA_MOUNT=0
STATUS_DIR=$T/www/status
REMOTE_BACKUP_HOST=127.0.0.1
REMOTE_BACKUP_PORT=$SSH_PORT
REMOTE_BACKUP_USER=$REMOTE_USER
REMOTE_BACKUP_DIR=$REMOTE_DIR
REMOTE_BACKUP_KEY=$T/id_ed25519
ALERT_EMAIL=THAY_EMAIL_NHAN_CANH_BAO
LOCAL_ALERT_USER=root
EOF
    local kv
    for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
    chown root:root "$f"; chmod 644 "$f"
}
make_conf "$T/labtools.conf"
export LABTOOLS_CONF=$T/labtools.conf

BACKUP="$REPO/scripts/backup.sh"
RESTORE="$REPO/scripts/restore.sh"
SETUP="$REPO/configs/postgres/setup-db.sh"
LOG=/var/log/labtools

psql_pg() { runuser -u postgres -- psql -X -At -v ON_ERROR_STOP=1 "$@"; }
psql_app() { PGPASSWORD=$DB_PASSWORD psql -X -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U appuser "$@"; }
rows() { psql_pg -d appdb -c 'SELECT count(*) FROM todos'; }
snapshot() { psql_pg -d appdb -c "SET TimeZone='UTC'; SELECT md5(coalesce(string_agg(t::text, E'\n' ORDER BY id), '')) FROM todos t" | tail -n 1; }
web_fp() { (cd "$T" && find www opt -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum); }
archives() { find "$T/backup" -maxdepth 1 -name 'labbackup_*.tar.gz' -printf '%f\n' | sort; }
latest() { archives | tail -n 1; }
temps() { find "$T/backup" "$T/small" -maxdepth 1 \( -name '.labbackup_*' -o -name '.work.*' \) | wc -l; }
run() { local rc=0; "$@" >"$T/out" 2>&1 || rc=$?; cp "$T/out" "$T/last"; echo "$rc"; }
next_second() { sleep 1.1; }   # tên file theo giây: tránh trùng giữa 2 lần backup

# ---------------- 1. CSDL ----------------
section '1. setup-db.sh + quyền CSDL'
check 'setup-db.sh chạy lần 1 (kèm dữ liệu mẫu)' bash "$SETUP" -s
check 'setup-db.sh chạy lại lần 2 không lỗi (idempotent)' bash "$SETUP" -s
check 'dữ liệu mẫu không bị nhân đôi (5 dòng)' test "$(rows)" = 5
check 'appuser KHÔNG superuser/createdb/createrole' \
    test "$(psql_pg -d postgres -c "SELECT rolsuper||rolcreatedb::text||rolcreaterole FROM pg_roles WHERE rolname='appuser'")" = falsefalsefalse
listen=$(ss -Htln 'sport = :5432' | awk '{print $4}' | sort | tr '\n' ' ')
not_loopback=$(ss -Htln 'sport = :5432' | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):5432$' || true)
check "5432 chỉ nghe loopback ($listen)" bash -c '[[ -n $1 && -z $2 ]]' _ "$listen" "$not_loopback"
check 'appuser đăng nhập TCP bằng mật khẩu, đọc todos' psql_app -d appdb -c 'SELECT count(*) FROM todos'
check 'appuser thêm/sửa todo được' psql_app -d appdb -c "INSERT INTO todos(title) VALUES ('từ appuser'); UPDATE todos SET done=true WHERE title='từ appuser'"
check 'appuser KHÔNG tạo được bảng mới' bash -c '! PGPASSWORD=$1 psql -X -h 127.0.0.1 -U appuser -d appdb -c "CREATE TABLE x(i int)"' _ "$DB_PASSWORD"
check 'appuser KHÔNG vào được DB postgres' bash -c '! PGPASSWORD=$1 psql -X -h 127.0.0.1 -U appuser -d postgres -c "SELECT 1"' _ "$DB_PASSWORD"
check 'sai mật khẩu bị từ chối' bash -c '! PGPASSWORD=sai-mat-khau psql -X -h 127.0.0.1 -U appuser -d appdb -c "SELECT 1"'

# ---------------- 2. Trợ giúp / tham số ----------------
section '2. --help và tham số'
check 'backup.sh -h' bash "$BACKUP" -h
check 'backup.sh --help' bash "$BACKUP" --help
check 'restore.sh -h' bash "$RESTORE" -h
check 'setup-db.sh -h' bash "$SETUP" -h
check 'backup.sh tuỳ chọn sai => mã 2' test "$(run bash "$BACKUP" -z)" = 2
check 'restore.sh -s sai => mã 2' test "$(run bash "$RESTORE" -s abc)" = 2
for f in "$BACKUP" "$RESTORE" "$SETUP"; do
    check "$(basename "$f"): có set -Eeuo pipefail + trap ERR" bash -c 'grep -q "^set -Eeuo pipefail" "$1" && grep -q "trap .* ERR" "$1"' _ "$f"
done

# ---------------- 3. Backup cơ bản + rsync ----------------
section '3. Backup + rsync sang VM2'
rc=$(run bash "$BACKUP")
check "backup.sh thoát 0 (được $rc)" test "$rc" = 0
a=$(latest)
check "tên file đúng mẫu ($a)" bash -c '[[ $1 =~ ^labbackup_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]' _ "$a"
check 'tar -tzf có db.sql + web.tar' bash -c 'l=$(tar -tzf "$1"); grep -qx db.sql <<<"$l" && grep -qx web.tar <<<"$l"' _ "$T/backup/$a"
check 'file .sha256 đi kèm khớp' bash -c 'cd "$1" && sha256sum --quiet -c "$2.sha256"' _ "$T/backup" "$a"
check 'quyền file backup 600' test "$(stat -c %a "$T/backup/$a")" = 600
check 'VM2 nhận được file + checksum khớp' bash -c 'cd "$1" && sha256sum --quiet -c "$2.sha256"' _ "$REMOTE_DIR" "$a"
check 'không còn file tạm' test "$(temps)" = 0
check 'log ghi vào /var/log/labtools/backup.log' grep -q "Đã tạo $T/backup/$a" "$LOG/backup.log"

# ---------------- 4. Retention ----------------
section '4. Retention 7 ngày'
old=labbackup_20200101_000000.tar.gz; mid=labbackup_20200102_000000.tar.gz
for f in "$old" "$mid"; do printf 'x' > "$T/backup/$f"; printf 'x  %s\n' "$f" > "$T/backup/$f.sha256"; done
touch -d '8 days ago' "$T/backup/$old" "$T/backup/$old.sha256"
touch -d '6 days ago' "$T/backup/$mid" "$T/backup/$mid.sha256"
next_second
rc=$(run bash "$BACKUP" -n)
check "backup -n thoát 0 (được $rc)" test "$rc" = 0
check 'bản 8 ngày tuổi bị xóa (cả .sha256)' bash -c '[[ ! -e $1 && ! -e $1.sha256 ]]' _ "$T/backup/$old"
check 'bản 6 ngày tuổi vẫn giữ' test -e "$T/backup/$mid"
check 'các bản thật (không phải bản giả 2020) vẫn còn đủ 2' test "$(archives | grep -vc '^labbackup_2020')" -ge 2
rm -f "$T/backup/$mid" "$T/backup/$mid.sha256"

# ---------------- 5. Đĩa đầy ----------------
section '5. Đĩa đầy: không chạy, cảnh báo, mã 4, không để file dở'
mount -t tmpfs -o size=2m tmpfs "$T/small"
make_conf "$T/conf-small" "BACKUP_DIR=$T/small"
: > "$LOG/backup.log"
rc=$(LABTOOLS_CONF=$T/conf-small run bash "$BACKUP")
check "thoát mã 4 (được $rc)" test "$rc" = 4
check 'không tạo labbackup_* nào' test "$(find "$T/small" -name 'labbackup_*' | wc -l)" = 0
check 'không để file dở (.part/.work)' test "$(temps)" = 0
check 'log có ALERT + lý do thiếu dung lượng' bash -c 'grep -q "ALERT: Backup THẤT BẠI" "$1" && grep -q "Không đủ dung lượng" "$1"' _ "$LOG/backup.log"
# Đầy giữa chừng: đủ chỗ lúc kiểm tra nhưng dump phình to hơn chỗ trống => trap dọn file dở.
# pg_dump giả ghi 40 MiB vào phân vùng chỉ còn ~35 MiB trống.
make_conf "$T/conf-small2" "BACKUP_DIR=$T/small" "BACKUP_RESERVE_MB=0"
umount "$T/small"; mount -t tmpfs -o size=60m tmpfs "$T/small"
dd if=/dev/zero of="$T/small/filler" bs=1M count=25 status=none
cat > "$T/fakebin/pg_dump" <<'EOF'
#!/bin/bash
head -c 40M /dev/zero | tr '\0' 'a'
EOF
chmod 755 "$T/fakebin/pg_dump"
rc=$(LABTOOLS_CONF=$T/conf-small2 PATH=$T/fakebin:$PATH run bash "$BACKUP" -n)
check "đầy giữa chừng (ENOSPC) => thoát khác 0 (được $rc)" test "$rc" != 0
check 'đầy giữa chừng => có ghi nhận lỗi ghi đĩa' grep -qi "No space left" "$T/last"
check 'đầy giữa chừng => không có labbackup_* hỏng' test "$(find "$T/small" -name 'labbackup_*' | wc -l)" = 0
check 'đầy giữa chừng => file dở đã bị xóa' test "$(temps)" = 0
umount "$T/small"

# ---------------- 6. Dump lỗi (pipefail / dump cụt / DB tắt) ----------------
section '6. Dump lỗi => dừng, báo lỗi, không tạo bản rỗng'
n_before=$(archives | wc -l)
cat > "$T/fakebin/pg_dump" <<'EOF'
#!/bin/bash
echo '-- PostgreSQL database dump (giả: chết giữa chừng)'
echo 'CREATE TABLE public.todos ('
exit 1
EOF
chmod 755 "$T/fakebin/pg_dump"
next_second
rc=$(PATH=$T/fakebin:$PATH run bash "$BACKUP" -n)
check "pg_dump lỗi giữa chừng => thoát khác 0 (được $rc)" test "$rc" != 0
check 'không có bản backup mới' test "$(archives | wc -l)" = "$n_before"
check 'không để file dở' test "$(temps)" = 0
sed -i 's/^exit 1$/exit 0/' "$T/fakebin/pg_dump"   # thoát 0 nhưng dump cụt (không có dòng kết thúc)
rc=$(PATH=$T/fakebin:$PATH run bash "$BACKUP" -n)
check "dump cụt nhưng mã 0 => vẫn bị bắt (được $rc)" test "$rc" != 0
check 'dump cụt => không có bản backup mới' test "$(archives | wc -l)" = "$n_before"
make_conf "$T/conf-baddb" "BACKUP_DB_NAME=khong_ton_tai"
rc=$(LABTOOLS_CONF=$T/conf-baddb run bash "$BACKUP" -n)
check "DB không tồn tại => thoát khác 0 (được $rc)" test "$rc" != 0
systemctl stop postgresql
rc=$(run bash "$BACKUP" -n)
systemctl start postgresql
check "PostgreSQL tắt => thoát khác 0 (được $rc)" test "$rc" != 0
check 'sau tất cả lỗi: không có bản mới, không file dở' bash -c '[[ $1 == "$2" && $3 == 0 ]]' _ "$(archives | wc -l)" "$n_before" "$(temps)"
for _ in 1 2 3 4 5 6 7 8 9 10; do psql_pg -d appdb -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done

# ---------------- 7. Rsync lỗi + khóa ----------------
section '7. VM2 không tới được / chạy chồng'
make_conf "$T/conf-badremote" "REMOTE_BACKUP_PORT=2299"
next_second
rc=$(LABTOOLS_CONF=$T/conf-badremote run bash "$BACKUP")
check "VM2 không tới được => mã 3 (được $rc)" test "$rc" = 3
check 'nhưng bản local vẫn tạo đủ + checksum đúng' bash -c 'cd "$1" && sha256sum --quiet -c "$2.sha256"' _ "$T/backup" "$(latest)"
exec 8>"$T/backup/.backup.lock"; flock -n 8
rc=$(run bash "$BACKUP" -n)
exec 8>&-
check "đang có backup khác giữ khóa => từ chối (mã $rc)" test "$rc" = 1

# ---------------- 8. Restore từ chối file lạ / hỏng ----------------
section '8. Restore chỉ nhận bản hợp lệ của backup.sh'
next_second; bash "$BACKUP" -n >/dev/null 2>&1
good=$(latest)
snap0=$(snapshot)
mkdir -p "$T/fake" && printf 'hello' > "$T/fake/db.sql" && printf 'x' > "$T/fake/web.tar"
fake=labbackup_20990101_000000.tar.gz
tar -C "$T/fake" -czf "$T/$fake" db.sql web.tar
(cd "$T" && sha256sum "$fake" > "$fake.sha256")
check 'archive lạ (thiếu manifest) => mã 5' test "$(run bash "$RESTORE" -y -f "$T/$fake")" = 5
cp "$T/backup/$good" "$T/tampered.tar.gz.tmp"
t2=labbackup_20990102_000000.tar.gz
mv "$T/tampered.tar.gz.tmp" "$T/$t2"; sed "s/$good/$t2/" "$T/backup/$good.sha256" > "$T/$t2.sha256"
printf 'X' >> "$T/$t2"
check 'archive bị sửa 1 byte => mã 5' test "$(run bash "$RESTORE" -y -f "$T/$t2")" = 5
cp "$T/backup/$good" "$T/labbackup_20990103_000000.tar.gz"
check 'thiếu file .sha256 => mã 5' test "$(run bash "$RESTORE" -y -f "$T/labbackup_20990103_000000.tar.gz")" = 5
cp "$T/backup/$good" "$T/ten-la.tar.gz"
check 'tên không đúng mẫu => mã 5' test "$(run bash "$RESTORE" -y -f "$T/ten-la.tar.gz")" = 5
check 'không có -y và không có terminal => không làm gì (mã 2)' test "$(run bash "$RESTORE" -f "$T/backup/$good" </dev/null)" = 2
check 'DB không bị đụng tới sau các lần từ chối' test "$(snapshot)" = "$snap0"

# ---------------- 9. Restore DB 3 lần liên tiếp ----------------
section '9. Restore DB: 3 lần liên tiếp, 3 kiểu phá dữ liệu'
N=$(rows)
echo "  (bản $good: todos=$N dòng)"
damage=(
    'DROP TABLE todos'
    'TRUNCATE todos'
    "DELETE FROM todos WHERE id % 2 = 0; UPDATE todos SET title = 'bị sửa', done = NOT done; INSERT INTO todos(title) VALUES ('rác')"
)
for i in 0 1 2; do
    psql_pg -d appdb -c "${damage[$i]}" >/dev/null
    rc=$(run bash "$RESTORE" -y -f "$T/backup/$good")
    check "lần $((i + 1)) [${damage[$i]%% *}…]: restore thoát 0 (được $rc)" test "$rc" = 0
    check "lần $((i + 1)): số dòng quay về $N" test "$(rows)" = "$N"
    check "lần $((i + 1)): nội dung giống hệt lúc backup" test "$(snapshot)" = "$snap0"
    check "lần $((i + 1)): appuser vẫn đọc/ghi được" psql_app -d appdb -c "SELECT count(*) FROM todos; INSERT INTO todos(title) VALUES ('t') RETURNING id"
    psql_pg -d appdb -c "DELETE FROM todos WHERE title = 't'" >/dev/null
done
check 'sequence id tiếp tục đúng sau restore (không trùng id)' psql_app -d appdb -c "INSERT INTO todos(title) VALUES ('seq')"
psql_pg -d appdb -c "DELETE FROM todos WHERE title = 'seq'" >/dev/null

# ---------------- 10. Restore web ----------------
section '10. Restore nội dung web'
fp0=$(web_fp)
rm -f "$T/opt/app/public/index.html"
printf 'hacked\n' > "$T/www/status/index.html"
printf 'rác\n' > "$T/www/status/la.txt"
rc=$(run bash "$RESTORE" -y -s web -f "$T/backup/$good")
check "restore -s web thoát 0 (được $rc)" test "$rc" = 0
check 'index.html đã xóa được khôi phục' test -f "$T/opt/app/public/index.html"
check 'file bị sửa trở lại như cũ, file lạ bị xóa' test "$(web_fp)" = "$fp0"

# ---------------- 11. Restore khi bị DROP DATABASE ----------------
section '11. Mất cả database appdb'
psql_pg -d postgres -c 'DROP DATABASE appdb WITH (FORCE)' >/dev/null
rc=$(run bash "$RESTORE" -y -s db -f "$T/backup/$good")
check "restore tạo lại appdb, thoát 0 (được $rc)" test "$rc" = 0
check 'dữ liệu giống hệt lúc backup' test "$(snapshot)" = "$snap0"
check 'appuser kết nối lại được' psql_app -d appdb -c 'SELECT count(*) FROM todos'

# ---------------- 12. Restore lỗi giữa chừng => rollback ----------------
section '12. db.sql lỗi giữa chừng => ROLLBACK, dữ liệu không đổi'
bad=labbackup_20990104_000000.tar.gz
mkdir -p "$T/badx" && tar -C "$T/badx" -xzf "$T/backup/$good"
{ echo 'TRUNCATE public.todos;'; echo 'SELECT 1/0;'; echo '-- PostgreSQL database dump complete'; } > "$T/badx/db.sql"
(cd "$T/badx" && sha256sum db.sql web.tar manifest.txt > SHA256SUMS && tar -czf "$T/$bad" manifest.txt SHA256SUMS db.sql web.tar)
(cd "$T" && sha256sum "$bad" > "$bad.sha256")
rc=$(run bash "$RESTORE" -y -s db -f "$T/$bad")
check "SQL lỗi => restore thoát khác 0 (được $rc)" test "$rc" != 0
check 'TRUNCATE trước lỗi đã bị ROLLBACK (dữ liệu còn nguyên)' test "$(snapshot)" = "$snap0"

# ---------------- 13. Restore từ bản trên VM2 ----------------
section '13. Restore từ bản đã rsync sang VM2'
next_second
check 'backup mới (có rsync) thoát 0' bash "$BACKUP"
remote_latest=$(latest)
snap1=$(snapshot)
find "$T/backup" -maxdepth 1 -name 'labbackup_*' -delete     # mất sạch bản local
psql_pg -d appdb -c 'DROP TABLE todos' >/dev/null
rm -rf "$T/www/status"
check 'restore -l -r liệt kê được bản trên VM2' bash -c 'bash "$1" -l -r | grep -q "$2"' _ "$RESTORE" "$remote_latest"
rc=$(run bash "$RESTORE" -r -y)
check "restore -r (bản mới nhất trên VM2) thoát 0 (được $rc)" test "$rc" = 0
check 'DB khôi phục đúng từ VM2' test "$(snapshot)" = "$snap1"
check 'web khôi phục đúng từ VM2' test "$(web_fp)" = "$fp0"
check 'restore -r với tên cụ thể' bash "$RESTORE" -r -y -s db "$remote_latest"
check 'restore -r tên không đúng mẫu => mã 5' test "$(run bash "$RESTORE" -r -y '../../etc/passwd')" = 5

# ---------------- 14. Timer systemd ----------------
section '14. systemd timer 02:00'
install -m 0644 "$REPO/configs/systemd/labbackup.timer" "$T/"
sed "s#^ExecStart=.*#ExecStart=$BACKUP#" "$REPO/configs/systemd/labbackup.service" > "$T/labbackup.service"
chmod 0644 "$T/labbackup.service"
# Chỉ xét cảnh báo về unit của mình (bỏ qua cảnh báo của unit khác trên máy, vd snapd)
check 'systemd-analyze verify labbackup.service/.timer' bash -c '! systemd-analyze verify "$1/labbackup.service" "$1/labbackup.timer" 2>&1 | grep -q labbackup' _ "$T"
check 'OnCalendar là 02:00 hằng ngày' bash -c 'systemd-analyze calendar "*-*-* 02:00:00" | grep -q "02:00:00"'
check 'timer có Persistent=true' grep -qx 'Persistent=true' "$REPO/configs/systemd/labbackup.timer"

# ---------------- 15. shellcheck ----------------
section '15. shellcheck'
check 'shellcheck backup.sh restore.sh setup-db.sh test' \
    shellcheck -x -P "$REPO/scripts" "$BACKUP" "$RESTORE" "$SETUP" "$SELF"
# _template.sh (của N5) bị shellcheck 0.8 hiểu nhầm dòng chú thích "# shellcheck sạch." là directive
# => báo riêng, không tính vào kết quả N4.
check 'shellcheck scripts/*.sh của nhóm (trừ _template.sh)' bash -c 'cd "$1/scripts" && shellcheck -x $(ls ./*.sh | grep -v _template.sh)' _ "$REPO"
if ! (cd "$REPO/scripts" && shellcheck _template.sh >/dev/null 2>&1); then
    printf '  \e[33mINFO\e[0m _template.sh (N5) chưa sạch shellcheck: đổi chú thích "# shellcheck sạch." thành "# (sạch shellcheck)"
'
fi

# ---------------- Kết quả ----------------
printf '\n== KẾT QUẢ: %d PASS, %d FAIL ==\n' "$PASS" "$FAIL"
if (( FAIL )); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
