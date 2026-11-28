# 4. CSDL, sao lưu và khôi phục (Người 4)

Phạm vi: PostgreSQL cho app todo, script sao lưu `scripts/backup.sh`, khôi phục `scripts/restore.sh`, lịch chạy 02:00 bằng systemd timer, và quy trình khôi phục đã kiểm thử.

| File nộp | Vai trò |
|---|---|
| `configs/postgres/99-lab.conf` | Cấu hình PostgreSQL: chỉ nghe `localhost`, mật khẩu `scram-sha-256`, ghi log kết nối |
| `configs/postgres/pg_hba.conf` | Ai được kết nối, từ đâu, bằng cách nào |
| `configs/postgres/schema.sql`, `sample-data.sql` | Bảng `todos` + quyền cho `appuser`; dữ liệu mẫu |
| `configs/postgres/setup-db.sh` | Cài cấu hình, tạo role/DB/bảng; chạy lại nhiều lần không lỗi |
| `scripts/backup.sh`, `scripts/restore.sh` | Sao lưu / khôi phục (dùng chung `scripts/lib.sh` của Người 5) |
| `configs/systemd/labbackup.service`, `labbackup.timer` | Chạy backup 02:00 hằng ngày |
| `tests/n4_backup_restore_test.sh` | Kiểm thử tự động 89 trường hợp |
| `tests/n4_demo.sh` | Cài đặt trên VM + đi qua checklist từng bước để chụp ảnh / tập restore |

## 4.1 Các bước xây dựng (quyết định then chốt)

**1. Cài PostgreSQL 14 từ kho Ubuntu 22.04**, không sửa thẳng `postgresql.conf` mà thêm `conf.d/99-lab.conf`. File gốc của gói giữ nguyên, cấu hình nhóm nằm trọn trong một file có trong repo, nâng cấp gói không ghi đè.

**2. Chỉ nghe localhost** (`listen_addresses = 'localhost'`). App (Người 3) chạy cùng máy và nối tới `127.0.0.1:5432`, nên không có lý do mở PostgreSQL ra mạng. Thêm vào đó UFW không mở 5432: hai lớp chặn độc lập.

**3. `pg_hba.conf` viết lại từ đầu, liệt kê đúng những gì được phép**, phần còn lại `reject`:

```
local   all       postgres                 peer            # quản trị: chỉ user hệ thống postgres
local   appdb     appuser                  scram-sha-256   # app qua socket
host    appdb     appuser   127.0.0.1/32   scram-sha-256   # app qua TCP localhost
host    appdb     appuser   ::1/128        scram-sha-256
local   all       all                      reject
host    all       all       0.0.0.0/0      reject
host    all       all       ::/0           reject
```

`postgres` dùng `peer` (phải là user Linux `postgres`, không có mật khẩu để đoán). `appuser` chỉ vào được `appdb`, chỉ từ máy này, và phải có mật khẩu băm `scram-sha-256` (không dùng `md5`, `trust`). Bản gốc được lưu thành `pg_hba.conf.orig` để so sánh/khôi phục.

**4. Role `appuser` quyền tối thiểu.** `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 20`. DB `appdb` do `postgres` sở hữu; `REVOKE ALL ON DATABASE appdb FROM PUBLIC` rồi chỉ `GRANT CONNECT` cho `appuser`; `REVOKE CREATE ON SCHEMA public FROM PUBLIC`. Trên bảng `todos` `appuser` chỉ có `SELECT, INSERT, UPDATE, DELETE` (+ `USAGE, SELECT` trên sequence) — đúng 4 thao tác app cần (`GET/POST/PUT /todos`). Nếu app bị chiếm quyền, kẻ tấn công không xóa được bảng, không tạo bảng/role, không đọc DB khác.

**5. Mật khẩu không nằm trong repo.** `setup-db.sh` đọc `DB_PASSWORD` từ `/etc/labapp/app.env` (file của Người 3, `640 root:appsvc`) và đưa vào `psql` qua stdin (`\set pw ...`), nên mật khẩu không hiện trong `ps`, lịch sử shell hay log.

**6. Bảng `todos`** đúng hợp đồng: `id SERIAL`, `title TEXT NOT NULL` (1–200 ký tự, ràng buộc `CHECK`), `done BOOLEAN DEFAULT FALSE`, `created_at TIMESTAMPTZ DEFAULT now()`. Script dùng `IF NOT EXISTS` nên chạy lại không lỗi.

> Lưu ý cho Người 3: vì `appuser` không có quyền `CREATE`, `init.sql` của app phải chạy bằng `postgres` (`sudo -u postgres psql -d appdb -f init.sql`), hoặc dùng luôn `configs/postgres/schema.sql`.

📷 `images/n4_db-roles.png` — `\du`: `appuser` không có Superuser/Create role/Create DB; `\dp todos`: `appuser=arwd`.
📷 `images/n4_db-listen.png` — `ss -tlnp | grep 5432` chỉ thấy `127.0.0.1:5432`; nội dung `pg_hba.conf` thực tế.

## 4.2 Sao lưu: `backup.sh`

```
sudo /opt/labtools/backup.sh        # backup + retention + rsync sang backup01
sudo /opt/labtools/backup.sh -n     # chỉ local
```

Mã thoát: `0` OK, `1` lỗi, `2` sai tham số/cấu hình, `3` bản local tốt nhưng rsync lỗi, `4` thiếu dung lượng. Mọi cấu hình đọc từ `/etc/labtools/labtools.conf` (`BACKUP_DIR`, `BACKUP_RETENTION_DAYS`, `REMOTE_BACKUP_*`), không hard-code.

Trình tự:

1. **Kiểm tra trước** (dòng 95–129): `/data` phải là mountpoint thật (nếu đĩa phụ chưa mount thì backup sẽ rơi vào ổ `/` → từ chối); giữ khóa `flock` để timer và người chạy tay không chạy chồng; dọn file tạm của lần chạy bị ngắt trước đó; **tính dung lượng cần** = (kích thước DB + nội dung web) × 2 + 100 MiB dự trữ, so với `df` của `/data/backup`. Thiếu → ghi log, `send_alert`, thoát mã 4, không tạo file nào.
2. **Dump + gói web vào thư mục tạm** `.work.*`: `pg_dump --clean --if-exists` (chạy bằng user `postgres` qua `peer`), kiểm tra dòng kết thúc `PostgreSQL database dump complete` để chặn dump bị cắt ngang; `tar` `/var/www/status` + `/opt/app/public` thành `web.tar`; ghi `manifest.txt` (người tạo, thời điểm, số dòng `todos`) và `SHA256SUMS`.
3. **Nén**: `tar ... | gzip -6 > .labbackup_*.part`, rồi `gzip -t`. Có `set -o pipefail` nên nếu `tar` lỗi thì cả đường ống lỗi (không ra file `.gz` "thành công" mà rỗng).
4. **Công bố nguyên tử**: tính sha256 → ghi `labbackup_YYYYmmdd_HHMMSS.tar.gz.sha256` → `mv` file `.part` thành tên chính thức (`mv` trong cùng phân vùng là nguyên tử). Quyền `600 root`: bản backup chứa toàn bộ dữ liệu.
5. **Retention 7 ngày**: xóa `labbackup_*.tar.gz` (và `.sha256`) cũ hơn `BACKUP_RETENTION_DAYS × 1440` phút; chỉ xóa sau khi bản mới đã tạo thành công, nên lỗi không bao giờ làm mất bản cũ.
6. **Rsync sang `backup01:/data/backup-recv`** qua SSH cổng 2222 bằng key (BatchMode, không hỏi mật khẩu), rồi chạy `sha256sum -c` **trên VM2** để chắc bản bên kia không hỏng. Rsync lỗi → cảnh báo, mã 3, bản local vẫn giữ.

**Xử lý lỗi**: `set -Eeuo pipefail` + `trap on_error ERR` + `trap cleanup EXIT`. Bất kỳ lệnh nào lỗi → xóa `.work.*`/`.part`, ghi log `/var/log/labtools/backup.log` kèm số dòng lỗi, gửi cảnh báo (msmtp, mất mạng thì mail local — `send_alert` của Người 5). Vì file chính thức chỉ xuất hiện ở bước 4, không bao giờ có bản backup dở dang mang tên hợp lệ.

📷 `images/n4_backup-archive.png` — `backup.sh -h`, chạy backup, `tar -tzvf` thấy `manifest.txt SHA256SUMS db.sql web.tar`.
📷 `images/n4_retention.png` — file giả `touch -d '8 days ago'` bị xóa, bản mới còn.
📷 `images/n4_rsync-vm2.png` — `ls -lh /data/backup-recv` trên `backup01`.
📷 `images/n4_disk-full.png` — BACKUP_DIR trên tmpfs 1 MiB: `cần ~117 MiB, còn 1 MiB`, `exit code = 4`, thư mục không có file backup nào, log + cảnh báo.
📷 `images/n4_dump-fail.png` — `pg_dump` chết giữa chừng: `Backup THẤT BẠI ở dòng 142`, `exit code = 1`, số bản backup trước = sau, 0 file `.part`.

## 4.3 Lịch: systemd timer

`labbackup.timer` (`OnCalendar=*-*-* 02:00:00`, `Persistent=true`) kích hoạt `labbackup.service` (`Type=oneshot`, `After=postgresql.service`, `RequiresMountsFor=/data`, `Nice=10`).

Chọn timer thay vì cron vì: `Persistent=true` chạy bù nếu máy tắt lúc 02:00; `RequiresMountsFor=/data` không chạy khi đĩa phụ chưa mount; log có sẵn trong `journalctl -u labbackup`; `systemctl list-timers` cho biết lần chạy trước/sau.

📷 `images/n4_timer.png` — `systemctl list-timers labbackup.timer`.

## 4.4 Khôi phục: `restore.sh`

```
sudo /opt/labtools/restore.sh -l                 # liệt kê bản backup
sudo /opt/labtools/restore.sh                    # bản mới nhất, hỏi xác nhận
sudo /opt/labtools/restore.sh -s db -y           # chỉ DB
sudo /opt/labtools/restore.sh -s web -y          # chỉ web
sudo /opt/labtools/restore.sh -r -y              # lấy bản mới nhất từ backup01
```

**Chỉ nhận bản do chính `backup.sh` tạo**, kiểm tra trước khi đụng vào hệ thống (sai bất kỳ bước nào → mã 5, không thay đổi gì): tên đúng mẫu `labbackup_YYYYmmdd_HHMMSS.tar.gz`; sha256 khớp file `.sha256` đi kèm; `gzip -t`; bên trong đúng 4 file; `manifest.txt` có `created_by=backup.sh`; `SHA256SUMS` bên trong khớp; `db.sql` có dòng kết thúc của `pg_dump`.

**Khôi phục DB** bằng `psql --single-transaction`: nếu `db.sql` lỗi giữa chừng, PostgreSQL ROLLBACK toàn bộ, DB giữ nguyên như trước khi restore (đã kiểm thử bằng `db.sql` cố tình lỗi). Nếu mất cả database `appdb` thì tạo lại trước.

**Kiểm tra toàn vẹn sau khôi phục**: số dòng `todos` = số trong `manifest.txt`; sha256 của toàn bộ dữ liệu `todos` (xuất bằng `COPY`) = sha256 dữ liệu trong `db.sql`; `appuser` vẫn còn đủ quyền; với web, sha256 từng file sau khi `rsync --delete` khớp nội dung trong `web.tar`.

### Quy trình demo (tập ≥3 lần trước buổi bảo vệ)

```
sudo -u postgres psql -d appdb -c 'SELECT count(*) FROM todos'   # 1. ghi nhớ N
sudo -u postgres psql -d appdb -c 'DROP TABLE todos'             # 2. phá dữ liệu
sudo /opt/labtools/restore.sh -y                                 # 3. khôi phục
sudo -u postgres psql -d appdb -c 'SELECT count(*) FROM todos'   # 4. lại N dòng
curl -sk https://app.lab.local/todos                             # 5. app thấy dữ liệu (F5 trình duyệt)
```

Hoặc chạy cả chuỗi 3 lần với 3 kiểu phá (DROP / TRUNCATE / DELETE): `sudo tests/n4_demo.sh restore`.

📷 `images/n4_restore-db.png` — 3 lần liên tiếp: N → phá → restore → N, kèm `GET /todos`.
📷 `images/n4_restore-web.png` — xóa `index.html` của status → `restore.sh -s web` → file trở lại.
📷 `images/n4_restore-vm2.png` — `restore.sh -r`: lấy bản từ `backup01`, kiểm checksum, khôi phục.

## 4.5 Kết quả kiểm thử

`tests/n4_backup_restore_test.sh` chạy bằng root trên Ubuntu 22.04 + PostgreSQL 14, dựng một "VM2" giả (sshd tạm + user riêng) để kiểm cả rsync và restore từ xa. Kết quả: **89 PASS, 0 FAIL**, gồm:

| Nhóm | Kiểm tra |
|---|---|
| CSDL | appuser không superuser/createdb/createrole, chỉ nghe 127.0.0.1, appuser không vào được DB `postgres`, không `CREATE TABLE` được |
| Backup | tên/timestamp đúng, đủ 4 file, rsync + checksum trên VM2, retention xóa bản > 7 ngày mà giữ bản mới |
| Đĩa đầy | thiếu chỗ trước khi chạy → mã 4 + cảnh báo; đầy **giữa chừng** (ENOSPC) → lỗi, không để file dở |
| Dump lỗi | `pg_dump` chết giữa chừng, dump cụt nhưng mã 0, DB không tồn tại, PostgreSQL tắt → đều dừng, không tạo bản rỗng |
| Khác | VM2 không tới được → mã 3, bản local còn; chạy chồng bị chặn bởi khóa |
| Restore | từ chối file sai tên / sai checksum / hỏng gzip / thiếu-thừa file / không phải của backup.sh; 3 lần liên tiếp với DROP, TRUNCATE, DELETE+UPDATE+INSERT; mất cả DB; `db.sql` lỗi → ROLLBACK; restore web; restore từ VM2 |
| Khác | `systemd-analyze verify` unit + timer; `shellcheck` sạch |

## 4.6 Câu hỏi vấn đáp tự đặt

1. **2 giờ sáng `/data` đầy thì sao?** `backup.sh` dòng 124–129 tính dung lượng cần (DB + web, ×2 cho bản tạm và bản nén, +100 MiB) và so với `df`. Thiếu → không chạy, ghi log, `send_alert` gửi mail, thoát mã 4; timer ghi nhận service failed. Nếu đầy *trong lúc* đang ghi (ví dụ file khác chiếm chỗ cùng lúc) thì lệnh ghi lỗi → trap ERR xóa `.part`/`.work`, cảnh báo; bản backup cũ không bị xóa vì retention chỉ chạy sau khi bản mới thành công.
2. **`pipefail` cứu gì trong `pg_dump | gzip`?** Không có `pipefail`, mã thoát của đường ống là mã của lệnh cuối (`gzip`), mà `gzip` nén một luồng rỗng/cụt vẫn thoát 0 → script tưởng thành công, tạo ra bản backup rỗng, rồi retention xóa bản tốt cũ. Có `pipefail`, lỗi của bất kỳ lệnh nào trong đường ống làm cả đường ống lỗi → `set -e` + trap ERR dừng lại. Script còn kiểm thêm dòng kết thúc của `pg_dump` và `gzip -t` cho trường hợp dump cụt mà vẫn thoát 0.
3. **Vì sao `appuser` không phải superuser? `pg_hba.conf` làm gì?** Quyền tối thiểu: app bị khai thác (SQL injection, lộ `app.env`) thì thiệt hại chỉ giới hạn ở 4 thao tác trên bảng `todos`; superuser thì đọc được mọi DB, chạy `COPY ... PROGRAM` thực thi lệnh hệ điều hành. `pg_hba.conf` là "tường lửa" của PostgreSQL: quyết định user nào, vào DB nào, từ địa chỉ nào, xác thực bằng phương thức gì; dòng đầu tiên khớp được áp dụng.
4. **Vì sao timestamp + retention 7 ngày?** Timestamp để mỗi lần chạy là một bản riêng, không ghi đè bản tốt bằng bản có thể hỏng, và biết chính xác dữ liệu thuộc thời điểm nào. Retention giới hạn dung lượng; 7 ngày đủ để phát hiện lỗi dữ liệu xảy ra từ vài ngày trước (ví dụ một bản ghi bị xóa nhầm được phát hiện vào cuối tuần), mà với dữ liệu nhỏ của app vẫn chiếm rất ít chỗ. Bản sao trên VM2 bảo vệ khi chính VM1 hỏng.
5. **Làm sao biết bản backup dùng được?** Không tin "script chạy xong": có checksum ở cả hai đầu rsync, và quan trọng nhất là đã restore thật nhiều lần, đối chiếu số dòng + checksum nội dung.

## 4.7 Bằng chứng ảnh

| Ảnh | Lệnh tạo (`sudo tests/n4_demo.sh <bước>`) |
|---|---|
| `n4_db-roles.png`, `n4_db-listen.png` | `db` |
| `n4_backup-archive.png` | `backup` |
| `n4_retention.png` | `retention` |
| `n4_rsync-vm2.png` | `remote` |
| `n4_disk-full.png` | `diskfull` |
| `n4_dump-fail.png` | `dumpfail` |
| `n4_timer.png` | `timer` |
| `n4_restore-db.png` | `restore` |
| `n4_restore-web.png` | `web` |
| `n4_restore-vm2.png` | `remote-restore` |

Ảnh chụp trên `web01`/`backup01` sau khi ráp (Mục 4 của kế hoạch). Ghi chú: yêu cầu "dump lỗi do sai mật khẩu" không áp dụng nguyên văn vì `pg_dump` chạy bằng user `postgres` qua `peer` (không dùng mật khẩu, không lưu mật khẩu nào cho backup); thay vào đó đã kiểm `pg_dump` lỗi giữa chừng, dump cụt, DB không tồn tại và PostgreSQL tắt.
