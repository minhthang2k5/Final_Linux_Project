#!/usr/bin/env bash
# ------------------------------------------------------------------
# n4_demo.sh — N4: cài đặt + đi qua checklist Người 4 trên VM thật (web01),
# từng bước in lệnh rồi chạy, dừng lại để chụp ảnh bằng chứng (report/images/n4_*.png).
# Dùng luôn để TẬP RESTORE trước buổi demo.
#
#   sudo tests/n4_demo.sh install          # cài script, timer, tạo DB (chạy 1 lần)
#   sudo tests/n4_demo.sh all              # đi qua mọi bước chụp ảnh
#   sudo tests/n4_demo.sh restore          # chỉ tập restore (3 lần, 3 kiểu phá dữ liệu)
#
# Cần sẵn: /etc/labtools/labtools.conf (N5), /data mount (N1), VM2 nhận backup (N1),
# DB_PASSWORD trong /etc/labapp/app.env (N3) hoặc biến môi trường DB_PASSWORD.
# ------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BIN=${N4_BIN:-/opt/labtools}
CONF=${LABTOOLS_CONF:-/etc/labtools/labtools.conf}
STEPS_ALL=(db backup retention remote diskfull dumpfail timer restore web remote-restore)
NO_PAUSE=0

usage() {
    cat <<EOF
Cách dùng: sudo ${SCRIPT_NAME} [-y] <bước>...

Bước:
  install         Cài backup.sh/restore.sh/lib.sh vào ${BIN}, cài + bật labbackup.timer,
                  chạy setup-db.sh -s (DB appdb, role appuser, bảng todos + dữ liệu mẫu)
  db              \\du, quyền bảng todos, ss 5432, pg_hba.conf          -> n4_db-roles, n4_db-listen
  backup          backup.sh -h, chạy backup, tar -tzvf                  -> n4_backup-archive
  retention       tạo bản giả cũ 8 ngày, backup, bản cũ bị xóa          -> n4_retention
  remote          ls /data/backup-recv trên VM2                         -> n4_rsync-vm2
  diskfull        BACKUP_DIR trên tmpfs 1 MiB: không chạy, mã 4, cảnh báo -> n4_disk-full
  dumpfail        pg_dump chết giữa chừng: dừng, không tạo bản rỗng      -> n4_dump-fail
  timer           systemctl list-timers labbackup.timer                 -> n4_timer
  restore         đếm N, phá dữ liệu (DROP/TRUNCATE/DELETE), restore x3  -> n4_restore-db
  web             xóa index.html của status, restore -s web             -> n4_restore-web
  remote-restore  restore -r (lấy bản từ VM2)                           -> n4_restore-vm2
  all             tất cả các bước trên (trừ install)

  -y    Không dừng chờ Enter giữa các bước
  -h    Trợ giúp (cũng nhận --help)

Biến môi trường: N4_BIN (mặc định /opt/labtools), LABTOOLS_CONF, DB_PASSWORD.
EOF
}

on_error() { local line=$1 code=$2; printf '\n[%s] LỖI ở dòng %s (mã %s)\n' "$SCRIPT_NAME" "$line" "$code" >&2; exit "$code"; }
trap 'on_error $LINENO $?' ERR

case ${1:-} in --help) usage; exit 0;; *) ;; esac
while getopts ':hy' opt; do
    case $opt in
        h) usage; exit 0;;
        y) NO_PAUSE=1;;
        *) printf 'Tuỳ chọn không hợp lệ: -%s\n' "$OPTARG" >&2; usage >&2; exit 2;;
    esac
done
shift "$((OPTIND - 1))"
if (( $# == 0 )); then usage >&2; exit 2; fi
if (( EUID != 0 )); then printf 'Chạy bằng sudo\n' >&2; exit 2; fi
cd /

# ---------------- tiện ích hiển thị ----------------
title() { printf '\n\e[1;36m==== %s ====\e[0m\n' "$*"; }
# run_cmd "<lệnh>": in giống dấu nhắc terminal rồi chạy; in mã thoát nếu khác 0 (không dừng script).
run_cmd() {
    local c=$1 rc=0
    printf '\e[1;32m%s@%s\e[0m:\e[1;34m~\e[0m# %s\n' "$(id -un)" "$(hostname)" "$c"
    bash -c "$c" || rc=$?
    if (( rc != 0 )); then printf '\e[33m(mã thoát: %s)\e[0m\n' "$rc"; fi
    return 0
}
pause() {
    local shot=$1
    printf '\e[35m>> Chụp màn hình lưu thành report/images/%s.png\e[0m\n' "$shot"
    if (( ! NO_PAUSE )) && [[ -t 0 ]]; then read -r -p '   Nhấn Enter để tiếp... ' _; clear; fi
}

load_conf() {
    if [[ ! -r "$CONF" ]]; then
        printf 'Chưa có %s — cài cấu hình của N5 trước (configs/labtools/labtools.conf.example)\n' "$CONF" >&2
        exit 2
    fi
    # shellcheck source=/dev/null
    source "$CONF"
    : "${BACKUP_DIR:=/data/backup}" "${BACKUP_DB_NAME:=appdb}" "${STATUS_DIR:=/var/www/status}"
    : "${REMOTE_BACKUP_USER:=sysadmin}" "${REMOTE_BACKUP_HOST:=192.168.56.20}"
    : "${REMOTE_BACKUP_PORT:=2222}" "${REMOTE_BACKUP_DIR:=/data/backup-recv}"
    : "${REMOTE_BACKUP_KEY:=/home/$REMOTE_BACKUP_USER/.ssh/id_ed25519}"
    ROWS="sudo -u postgres psql -X -At -d $BACKUP_DB_NAME -c 'SELECT count(*) AS todos FROM todos'"
}
latest() { find "$BACKUP_DIR" -maxdepth 1 -name 'labbackup_*.tar.gz' -printf '%p\n' | sort | tail -n 1; }
# Tên backup tính theo giây: chờ sang giây mới để 2 lần backup liền nhau không trùng tên.
next_second() { local now; now=$(date +%s); while [[ $(date +%s) == "$now" ]]; do sleep 0.2; done; }
count_archives() { find "$BACKUP_DIR" -maxdepth 1 -name 'labbackup_*.tar.gz' | wc -l; }

# ---------------- các bước ----------------
step_install() {
    title 'Cài đặt N4'
    local f
    install -d -o root -g root -m 0755 "$BIN"
    for f in lib.sh backup.sh restore.sh; do
        install -o root -g root -m 0755 "$REPO/scripts/$f" "$BIN/$f"
    done
    run_cmd "ls -l $BIN"
    install -o root -g root -m 0644 "$REPO/configs/systemd/labbackup.service" /etc/systemd/system/labbackup.service
    install -o root -g root -m 0644 "$REPO/configs/systemd/labbackup.timer" /etc/systemd/system/labbackup.timer
    systemctl daemon-reload
    systemctl enable --now labbackup.timer
    if [[ -n "${DB_PASSWORD:-}" || -r /etc/labapp/app.env ]]; then
        bash "$REPO/configs/postgres/setup-db.sh" -s
    else
        printf '\e[33mChưa có DB_PASSWORD: tạo /etc/labapp/app.env (N3) hoặc chạy:\n'
        printf '  sudo DB_PASSWORD=... %s/configs/postgres/setup-db.sh -s\e[0m\n' "$REPO"
    fi
    load_conf
    install -d -o root -g root -m 0750 "$BACKUP_DIR"
    run_cmd "systemctl list-timers labbackup.timer --no-pager"
}

step_db() {
    title 'CSDL: appuser không phải superuser, chỉ nghe localhost'
    run_cmd "sudo -u postgres psql -X -c '\\du'"
    run_cmd "sudo -u postgres psql -X -d $BACKUP_DB_NAME -c '\\dp todos'"
    pause n4_db-roles
    run_cmd "ss -tlnp | grep 5432"
    run_cmd "grep -Ev '^[[:space:]]*(#|\$)' /etc/postgresql/*/main/pg_hba.conf"
    run_cmd "sudo -u postgres psql -X -At -c 'SHOW listen_addresses'"
    pause n4_db-listen
}

step_backup() {
    title 'Backup: tạo labbackup_YYYYmmdd_HHMMSS.tar.gz'
    run_cmd "$BIN/backup.sh -h"
    next_second
    run_cmd "$BIN/backup.sh"
    run_cmd "ls -lh $BACKUP_DIR"
    run_cmd "tar -tzvf $(latest)"
    pause n4_backup-archive
}

step_retention() {
    title 'Retention 7 ngày'
    local old
    old="$BACKUP_DIR/labbackup_$(date -d '8 days ago' +%Y%m%d_%H%M%S).tar.gz"
    run_cmd "touch -d '8 days ago' $old $old.sha256"
    run_cmd "ls -l --time-style=+%F $BACKUP_DIR"
    next_second
    run_cmd "$BIN/backup.sh -n"
    run_cmd "ls -l --time-style=+%F $BACKUP_DIR"
    pause n4_retention
}

step_remote() {
    title 'Rsync sang VM2'
    run_cmd "sudo -u $REMOTE_BACKUP_USER ssh -o BatchMode=yes -p $REMOTE_BACKUP_PORT -i $REMOTE_BACKUP_KEY $REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST 'hostname; ls -lh $REMOTE_BACKUP_DIR'"
    pause n4_rsync-vm2
}

step_diskfull() {
    title 'Đĩa đầy: không chạy, cảnh báo, mã thoát 4, không để file dở'
    local small=/mnt/n4-small conf
    conf=$(mktemp /root/n4-demo-conf.XXXXXX)
    mkdir -p "$small"
    mountpoint -q "$small" || mount -t tmpfs -o size=1m tmpfs "$small"
    { cat "$CONF"; printf 'BACKUP_DIR=%s\nREQUIRE_DATA_MOUNT=0\n' "$small"; } > "$conf"
    chmod 644 "$conf"
    run_cmd "df -h $small"
    run_cmd "LABTOOLS_CONF=$conf $BIN/backup.sh -n; echo \"exit code = \$?\""
    run_cmd "ls -la $small"
    run_cmd "tail -n 3 /var/log/labtools/backup.log"
    pause n4_disk-full
    umount "$small"; rmdir "$small"; rm -f "$conf"
}

step_dumpfail() {
    title 'pg_dump chết giữa chừng: dừng, báo lỗi, không tạo bản rỗng'
    local fake n0
    fake=$(mktemp -d /tmp/n4-fakebin.XXXXXX)
    chmod 755 "$fake"
    printf '%s\n' '#!/bin/bash' "echo '-- dump giả, chết giữa chừng'" 'exit 1' > "$fake/pg_dump"
    chmod 755 "$fake/pg_dump"
    n0=$(count_archives)
    run_cmd "ls $BACKUP_DIR | wc -l"
    next_second
    run_cmd "PATH=$fake:\$PATH $BIN/backup.sh -n; echo \"exit code = \$?\""
    run_cmd "ls -A $BACKUP_DIR | grep -c -e '\\.part' -e '\\.work' || true"
    printf 'Số bản backup: trước %s, sau %s\n' "$n0" "$(count_archives)"
    pause n4_dump-fail
    rm -rf -- "$fake"
}

step_timer() {
    title 'Lịch 02:00 hằng ngày'
    run_cmd "systemctl list-timers labbackup.timer --no-pager"
    run_cmd "systemctl cat labbackup.timer --no-pager"
    pause n4_timer
}

step_restore() {
    title 'Restore DB 3 lần liên tiếp'
    local damage i
    damage=(
        'DROP TABLE todos'
        'TRUNCATE todos'
        "DELETE FROM todos WHERE id % 2 = 0"
    )
    next_second
    run_cmd "$BIN/backup.sh -n"
    run_cmd "$ROWS"
    for i in 0 1 2; do
        printf '\n\e[1m-- Lần %s: %s\e[0m\n' "$((i + 1))" "${damage[$i]}"
        run_cmd "sudo -u postgres psql -X -d $BACKUP_DB_NAME -c \"${damage[$i]}\""
        run_cmd "$ROWS"
        run_cmd "$BIN/restore.sh -s db -y"
        run_cmd "$ROWS"
    done
    if ss -Htln 'sport = :5000' | grep -q .; then
        run_cmd "curl -s 127.0.0.1:5000/todos | head -c 400; echo"
    fi
    pause n4_restore-db
}

step_web() {
    title 'Restore nội dung web'
    local f=$STATUS_DIR/index.html
    if [[ ! -e "$f" ]]; then f=$(find "$STATUS_DIR" -type f | head -n 1); fi
    if [[ -z "$f" ]]; then printf '%s đang trống, bỏ qua\n' "$STATUS_DIR"; return 0; fi
    next_second
    run_cmd "$BIN/backup.sh -n"
    run_cmd "ls -l $STATUS_DIR"
    run_cmd "rm -f $f"
    run_cmd "ls -l $STATUS_DIR"
    run_cmd "$BIN/restore.sh -s web -y"
    run_cmd "ls -l $STATUS_DIR"
    pause n4_restore-web
}

step_remote_restore() {
    title 'Restore từ bản trên VM2'
    run_cmd "sudo -u postgres psql -X -d $BACKUP_DB_NAME -c 'TRUNCATE todos'"
    run_cmd "$ROWS"
    run_cmd "$BIN/restore.sh -r -y"
    run_cmd "$ROWS"
    pause n4_restore-vm2
}

# ---------------- chạy ----------------
steps=()
for s in "$@"; do
    case $s in
        all) steps+=("${STEPS_ALL[@]}");;
        install|db|backup|retention|remote|diskfull|dumpfail|timer|restore|web|remote-restore) steps+=("$s");;
        *) printf 'Bước không hợp lệ: %s\n' "$s" >&2; usage >&2; exit 2;;
    esac
done
for s in "${steps[@]}"; do
    if [[ $s != install ]]; then load_conf; fi
    case $s in
        install) step_install;;
        db) step_db;;
        backup) step_backup;;
        retention) step_retention;;
        remote) step_remote;;
        diskfull) step_diskfull;;
        dumpfail) step_dumpfail;;
        timer) step_timer;;
        restore) step_restore;;
        web) step_web;;
        remote-restore) step_remote_restore;;
        *) ;;
    esac
done
title 'Xong'
