# Kế hoạch chia việc — Đồ án Linux (nhóm 5 người)

Nguyên tắc: **mỗi người làm độc lập trên VM riêng, chỉ nối với nhau qua "hợp đồng" (Mục 1)**. Phần chưa có của người khác thì dùng mock (Mục 3). Cuối cùng ráp vào VM1 + VM2 (Mục 4).

## 1. Hợp đồng chung (CẢ NHÓM CHỐT NGÀY 1, KHÔNG ĐỔI SAU ĐÓ)

| Hạng mục | Giá trị |
|---|---|
| OS | Ubuntu 22.04 LTS Server (cả nhóm giống nhau) |
| Trình ảo hóa | VirtualBox |
| VM1 | hostname `web01`, IP Host-Only `192.168.56.10` |
| VM2 | hostname `backup01`, IP Host-Only `192.168.56.20` |
| User quản trị | `sysadmin` (sudo) |
| SSH port | `2222` (AllowUsers `sysadmin`) |
| Web server | Nginx |
| Vhost 1 (app) | `app.lab.local` → proxy tới `127.0.0.1:5000` |
| Vhost 2 (tĩnh) | `status.lab.local` → `/var/www/status` |
| App | Node.js + Express (thư viện `pg`), code ở `/opt/app`, chạy `node server.js`, user hệ thống `appsvc`. Cài Node.js 20 LTS từ NodeSource (KHÔNG dùng `apt` mặc định: Ubuntu 22.04 chỉ có Node 12) |
| Service systemd | `labapp.service` |
| File bí mật | `/etc/labapp/app.env` (root:appsvc, mode 640) |
| Biến trong app.env | `DB_HOST=127.0.0.1` `DB_PORT=5432` `DB_NAME=appdb` `DB_USER=appuser` `DB_PASSWORD=...` |
| CSDL | PostgreSQL, DB `appdb`, role `appuser`, bảng `todos(id, title, done, created_at)` |
| Loại app | Todo list (Node.js/Express) |
| Frontend | HTML/CSS/JS thuần (không framework), file `app/public/index.html`, Express phục vụ bằng `express.static('public')`, gọi API bằng `fetch()` |
| Endpoint app | `GET /todos` (đọc), `POST /todos` (ghi), `PUT /todos/<id>` (đánh dấu xong), `GET /health` |
| Phân vùng dữ liệu | đĩa phụ mount `/data` qua fstab; backup ở `/data/backup` |
| Nơi nhận backup (VM2) | `backup01:/data/backup-recv`, user `sysadmin`, SSH key không mật khẩu |
| Thư mục script | `/opt/labtools/` (cài từ `scripts/` trong repo) |
| File cấu hình công cụ | `/etc/labtools/labtools.conf` (ngưỡng CPU/RAM/disk, email nhận cảnh báo, số ngày giữ backup) |
| Log công cụ | `/var/log/labtools/*.log` |
| Retention backup | 7 ngày |
| Nội dung web được backup | `/var/www/status` và `/opt/app/public` (gói thành `web.tar`) |
| Tên file backup | `labbackup_YYYYmmdd_HHMMSS.tar.gz` (chứa `db.sql` + `web.tar`) |
| Cổng firewall mở | 2222/tcp (SSH), 80/tcp, 443/tcp |

Cấu trúc repo Git:

```
Final_project/
├── app/                 # NGƯỜI 3
├── configs/
│   ├── nginx/           # NGƯỜI 2
│   ├── tls/             # NGƯỜI 2 (script tạo cert, KHÔNG commit private key)
│   ├── ssh/ ufw/ fail2ban/ auditd/    # NGƯỜI 1
│   ├── systemd/         # NGƯỜI 3
│   └── postgres/        # NGƯỜI 4
├── scripts/             # NGƯỜI 4 (backup/restore) + NGƯỜI 5 (menu, deploy, healthcheck, logrotate)
├── report/              # mỗi người viết phần mình
└── README.md
```

## 2. Phân công chi tiết

Mỗi người có **checklist hoàn thành** ở cuối mục của mình. Làm xong phần mình thì tự đi qua checklist: tick `[x]` từng dòng **sau khi đã chạy lệnh kiểm tra và thấy kết quả đúng**. Chụp ảnh các dòng có 📷 làm bằng chứng cho báo cáo (đặt vào `report/images/`, tên `n<số>_<nội-dung>.png`). Xong phần "Hiểu để trả lời" thì nhờ một người khác hỏi thử. Đi qua checklist **hai lần**: ngày 6 (trước khi báo xong giai đoạn làm riêng) và ngày 11 (sau khi ráp).

Quy ước: 📷 = cần ảnh bằng chứng, 📄 = cần file thật có trong repo.

### Người 1 (Minh Thắng, nhóm trưởng) — Hạ tầng, mạng, gia cố hệ thống
**Làm trước tiên, ngày 1: giao VM chuẩn cho cả nhóm.**
- Dựng VM Ubuntu Server, đặt hostname, tạo `sysadmin`, mạng NAT + Host-Only. Export `.ova` gửi nhóm.
- Dựng VM2 `backup01`, tạo `/data/backup-recv`, SSH key cho rsync.
- Thêm đĩa phụ, format, mount `/data` qua `/etc/fstab` (kiểm tra sau reboot).
- Firewall UFW: default deny incoming, mở 2222/80/443, ghi lý do từng cổng. Viết `configs/ufw/setup-ufw.sh` và xuất `ufw status verbose` + `/etc/ufw/user.rules` làm "file thật" để nộp.
- SSH hardening: PermitRootLogin no, key auth, port 2222, AllowUsers. **Chốt:** để `PasswordAuthentication yes` trong lúc demo ban fail2ban (fail2ban chỉ đếm tốt lần thử mật khẩu sai), nêu rõ đánh đổi trong báo cáo (dễ bị dò mật khẩu, được fail2ban giảm nhẹ); sau demo tắt lại hoặc giữ kèm giải thích.
- fail2ban cho SSH (+ jail nginx nếu có login): jail `sshd` phải có `port = 2222`, `maxretry` nhỏ (3), `bantime` ngắn (vd 10 phút), `ignoreip` chứa IP máy dùng để điều khiển demo (để lỡ ban nhầm không bị khóa). **Mô phỏng tấn công:** từ VM2 (hoặc máy Windows) chạy `hydra` / vòng lặp `ssh` sai mật khẩu vào `192.168.56.10:2222`; xem `fail2ban-client status sshd`; gỡ ban bằng `fail2ban-client set sshd unbanip <IP>` để chạy lại. Nếu dùng VM2 làm máy tấn công thì không để VM2 trong `ignoreip`.
- auditd theo dõi `/etc/passwd`, `/etc/shadow`: rule `-w ... -p rwa -k identity`, xem bằng `ausearch -k identity`.
- Chạy Lynis, ghi điểm **trước và sau**, sửa ≥3 mục (nêu tên từng mục đã khắc phục). SSH ProxyJump (nếu dùng VM2 làm bastion).
- **Đầu ra:** file `.ova`, `configs/ssh|ufw|fail2ban|auditd`, sơ đồ VM, ảnh Lynis.
- **Demo:** trạng thái ufw, ban fail2ban trực tiếp, `ausearch` bắt truy cập shadow.
- **Chuẩn bị trả lời:** vì sao mở từng cổng; từng dòng sshd_config chặn gì; fail2ban hoạt động ra sao.

#### Checklist hoàn thành — Người 1 (Minh Thắng)

##### Hạ tầng
- [ ] VM1 có hostname `web01`, VM2 có hostname `backup01` — `hostnamectl` 📷
- [ ] Làm việc bằng user `sysadmin` có sudo, không dùng root — `sudo -l -U sysadmin`
- [ ] File `.ova` VM trơn đã giao cho cả nhóm (ngày 1) và mọi người import được
- [ ] Hai VM ping nhau qua Host-Only, và máy Windows SSH vào được cả hai
- [ ] Đĩa phụ mount `/data` qua `/etc/fstab` (dùng UUID) — `findmnt /data`, `sudo mount -a` không lỗi 📷📄
- [ ] **Reboot VM1, `/data` vẫn còn** — `df -h /data` sau reboot 📷
- [ ] VM2 có `/data/backup-recv`, VM1 SSH sang VM2 bằng key không mật khẩu — `ssh backup01 true` không hỏi mật khẩu
- [ ] Sơ đồ VM + chế độ mạng đã vẽ cho báo cáo 📄

##### Tường lửa
- [ ] UFW bật, mặc định chặn chiều vào — `sudo ufw status verbose` ghi `deny (incoming)` 📷
- [ ] Chỉ mở 2222/tcp, 80/tcp, 443/tcp; không có cổng thừa
- [ ] Đã ghi lý do mở từng cổng + kẻ tấn công được lợi gì từ cổng đó
- [ ] `configs/ufw/setup-ufw.sh` + `ufw status verbose` + `/etc/ufw/user.rules` đã nằm trong repo 📄

##### SSH
- [ ] `sudo sshd -t` không báo lỗi
- [ ] `sudo sshd -T | grep -Ei 'permitrootlogin|port |allowusers|pubkeyauthentication|passwordauthentication'` đúng như thiết kế 📷
- [ ] Thử SSH bằng root → bị từ chối; SSH bằng `sysadmin` + key → được
- [ ] Đã ghi đánh đổi nếu bật mật khẩu lúc demo
- [ ] `configs/ssh/sshd_config` có trong repo 📄
- [ ] (Nếu dùng) ProxyJump hoạt động — `ssh -J ... web01`

##### fail2ban
- [ ] Jail `sshd` bật với `port = 2222`, `maxretry`, `bantime`, `ignoreip` hợp lý — `fail2ban-client status sshd` 📷
- [ ] **Đã ban thử thành công**: tấn công từ VM2 → IP bị ban → gỡ ban (`fail2ban-client set sshd unbanip ...`) 📷
- [ ] `configs/fail2ban/jail.local` có trong repo 📄

##### auditd
- [ ] Rule theo dõi `/etc/passwd`, `/etc/shadow` — `sudo auditctl -l` 📷
- [ ] Chạy `sudo cat /etc/shadow` rồi `sudo ausearch -k identity` thấy dấu vết đọc được 📷
- [ ] `configs/auditd/*.rules` có trong repo 📄

##### Lynis
- [ ] Chạy Lynis, ghi **điểm trước** (hardening index) 📷
- [ ] Sửa ≥3 mục, ghi tên từng mục đã sửa
- [ ] Chạy lại, ghi **điểm sau** 📷

##### Hiểu để trả lời
- [ ] Giải thích vì sao mở từng cổng, kẻ tấn công được lợi gì
- [ ] Giải thích từng dòng trong `sshd_config` chặn điều gì
- [ ] Giải thích fail2ban đọc log nào, ban bằng cách nào (iptables/nftables)
- [ ] Giải thích fstab: vì sao UUID, `nofail`, chuyện gì xảy ra nếu đĩa thiếu

### Người 2 — Nginx, vhost, TLS
- Cài Nginx, 2 vhost (`app.lab.local`, `status.lab.local`), trang tĩnh status.
- reverse proxy: `proxy_pass http://127.0.0.1:5000`, header `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
- TLS tự ký bằng openssl, HTTPS cho cả 2 vhost, 80 → 301 → 443.
- Viết giải thích vì sao không dùng Let's Encrypt (VM Host-Only, không domain công khai, ACME không truy cập được).
- **Đầu ra:** `configs/nginx/*`, script tạo cert, ảnh `curl -kI`, `curl -H "Host: ..."`.
- **Mock:** `python3 -m http.server 5000` thay app.
- **Demo:** curl cả 2 vhost, redirect 80→443, HTTPS endpoint.
- **Chuẩn bị trả lời:** đường đi của 1 request qua Nginx; mỗi header để làm gì; tự ký vs CA.

#### Checklist hoàn thành — Người 2

##### Nginx
- [ ] `sudo nginx -t` báo OK
- [ ] Có ≥2 vhost: `app.lab.local` (proxy) và `status.lab.local` (tĩnh)
- [ ] `curl -H "Host: app.lab.local" http://192.168.56.10` và `curl -H "Host: status.lab.local" ...` đều phản hồi đúng, **mỗi vhost ra nội dung khác nhau** 📷
- [ ] `proxy_pass http://127.0.0.1:5000` và các header `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto` đã đặt
- [ ] Đã kiểm tra header thực sự tới app (xem log app hoặc dùng app giả in header) 📷
- [ ] File cấu hình nằm trong `configs/nginx/` 📄

##### TLS / HTTPS
- [ ] Cert + key tự ký tạo bằng openssl — `openssl x509 -in ... -noout -subject -dates` 📷
- [ ] Key riêng quyền chặt (`600`, root) và **không commit** vào repo
- [ ] HTTPS hoạt động cho cả 2 vhost — `curl -k https://...` 📷
- [ ] HTTP → HTTPS: `curl -I http://...` trả `301` với `Location: https://...` 📷
- [ ] Cổng 443 đã mở trên UFW (phối hợp Người 1) — `curl` từ máy khác tới được
- [ ] Script tạo cert nằm trong `configs/tls/` 📄
- [ ] Đã viết phần lập luận: vì sao không dùng Let's Encrypt (VM Host-Only, không domain công khai, ACME không tới được) 📄

##### Hiểu để trả lời
- [ ] Kể từng bước một request đi từ trình duyệt → Nginx → app → DB → trả về
- [ ] Mỗi header proxy để làm gì; thiếu `X-Forwarded-For` thì app thấy IP nào
- [ ] Cert tự ký khác CA thật ở đâu; vì sao trình duyệt cảnh báo
- [ ] `reload` khác `restart` thế nào; `nginx -t` để làm gì

### Người 3 — Ứng dụng + systemd
- Frontend: một trang `app/public/index.html` (HTML/CSS/JS thuần) hiển thị, thêm, đánh dấu xong việc cần làm qua `fetch()`; không dùng React/Vue.
- Express app Todo list (Node.js 20 LTS cài từ NodeSource; không dùng `apt` mặc định vì chỉ có Node 12): `GET/POST /todos`, `PUT /todos/<id>`, `GET /health`, đọc cấu hình từ biến môi trường, không hard-code.
- Kết nối PostgreSQL bằng `appuser`; script `init.sql` tạo bảng.
- `labapp.service`: `Restart=on-failure`, `EnvironmentFile=/etc/labapp/app.env`, `User=appsvc`, log ra journald.
- File `app.env` quyền 640, chụp `ls -l`.
- **Đầu ra:** `app/`, `configs/systemd/labapp.service`, `app.env.example`, ảnh status/journalctl.
- **Mock:** tự cài Postgres tạm trên VM của mình theo đúng hợp đồng.
- **Demo:** `systemctl status` (active+enabled), `kill` app → systemd tự bật lại → xem `journalctl`.
- **Chuẩn bị trả lời:** Restart=on-failure vs always; EnvironmentFile vì sao; app nói chuyện DB thế nào.

#### Checklist hoàn thành — Người 3

##### Ứng dụng
- [ ] Node.js 20 cài từ NodeSource — `node -v`
- [ ] `GET /health` trả 200 và kiểm cả DB — `curl 127.0.0.1:5000/health` 📷
- [ ] `GET /todos` trả danh sách; `POST /todos` thêm được; `PUT /todos/<id>` đánh dấu xong 📷
- [ ] `public/index.html` mở được qua `https://app.lab.local`: xem, thêm, đánh dấu xong 📷
- [ ] `init.sql` chạy lại nhiều lần không lỗi (dùng `IF NOT EXISTS`)
- [ ] App kết nối DB bằng `appuser`, **không dùng** tài khoản `postgres`
- [ ] Không có mật khẩu hard-code — `grep -rni "password" app/` chỉ thấy tên biến
- [ ] Code + `package.json` + `app.env.example` nằm trong `app/` 📄

##### systemd
- [ ] `labapp.service` có `Restart=on-failure`, `EnvironmentFile=/etc/labapp/app.env`, `User=appsvc` 📄
- [ ] `systemctl status labapp` thấy `active (running)` và `enabled` 📷
- [ ] Reboot VM, app tự lên — `systemctl is-enabled labapp`
- [ ] `ls -l /etc/labapp/app.env` quyền `640`, chủ `root:appsvc` 📷
- [ ] App chạy bằng `appsvc` không phải root — `ps -o user,cmd -C node`
- [ ] **Kill app**: `sudo kill -9 <pid>` → app tự khởi động lại; `journalctl -u labapp -n 20` thấy sự kiện 📷
- [ ] Log app ra stdout/stderr và xem được bằng journald

##### Hiểu để trả lời
- [ ] `Restart=on-failure` khác `always`, khác `no` thế nào; khi `systemctl stop` thì có restart không
- [ ] Vì sao dùng `EnvironmentFile`, vì sao quyền `640`
- [ ] App đọc cấu hình và kết nối DB ra sao (pool, biến môi trường)
- [ ] Vì sao app nghe `127.0.0.1` chứ không phải `0.0.0.0`

### Người 4 — CSDL + sao lưu/khôi phục
- Cài PostgreSQL, tạo DB `appdb`, role `appuser` quyền tối thiểu (không superuser); `listen_addresses='localhost'`, `pg_hba.conf` chỉ local. Chụp `ss -tlnp`.
- `scripts/backup.sh`: `pg_dump` + tar nội dung web → nén → timestamp → xóa bản >7 ngày → rsync sang VM2. getopts, `--help`, `set -euo pipefail`, trap ERR. **Kiểm tra dung lượng đĩa trước khi chạy: nếu `/data` không đủ chỗ thì không chạy, gọi `send_alert` và thoát với mã lỗi** (đây là câu trả lời cho câu vấn đáp "2 giờ sáng đĩa đầy thì sao"). Nếu dump hoặc nén lỗi giữa chừng thì xóa file dở, không để lại bản hỏng, và cảnh báo. Nội dung web = `/var/www/status` + `/opt/app/public` (xem hợp đồng).
- `scripts/restore.sh`: khôi phục DB + web từ bản backup do chính backup.sh tạo; kiểm tra toàn vẹn (đếm dòng, checksum).
- Lịch: systemd timer hoặc cron (ví dụ 02:00 hằng ngày).
- **Đầu ra:** `configs/postgres/`, `scripts/backup.sh`, `scripts/restore.sh`, file timer, ảnh test restore.
- **Mock:** DB mẫu có vài dòng; rsync thử sang thư mục local hoặc VM thứ hai của mình.
- **Demo:** backup + rsync + xóa bản cũ; DROP/xóa dữ liệu → restore → dữ liệu còn nguyên.
- **Chuẩn bị trả lời:** nếu 2h sáng đĩa đầy thì sao; vì sao `pipefail` quan trọng với `pg_dump | gzip`; tập restore NHIỀU LẦN (mất trọn 20% điểm nếu fail).

#### Checklist hoàn thành — Người 4

##### CSDL
- [ ] DB `appdb`, role `appuser` — `\du` cho thấy **không phải superuser** 📷
- [ ] `appuser` chỉ có quyền cần thiết trên bảng `todos` (không `CREATEDB`, không `CREATEROLE`)
- [ ] `listen_addresses = 'localhost'` — `ss -tlnp | grep 5432` chỉ thấy `127.0.0.1:5432` 📷
- [ ] `pg_hba.conf` chỉ cho phép local; cấu hình nằm trong `configs/postgres/` 📄

##### Backup
- [ ] `backup.sh -h` hiển thị trợ giúp; có `set -euo pipefail` và `trap ... ERR`
- [ ] Tạo file `labbackup_YYYYmmdd_HHMMSS.tar.gz` — `tar -tzf` thấy `db.sql` + `web.tar` 📷
- [ ] File được nén và có timestamp
- [ ] **Retention**: tạo file giả cũ hơn 7 ngày (`touch -d '8 days ago'`), chạy backup → file cũ bị xóa, file mới còn 📷
- [ ] **rsync** sang VM2: `ls /data/backup-recv` trên VM2 thấy file 📷
- [ ] **Đĩa đầy**: giả lập thiếu chỗ → script không chạy, cảnh báo, thoát mã lỗi, không để file dở 📷
- [ ] Dump lỗi (vd sai mật khẩu) → script **dừng và báo lỗi**, không tạo bản backup rỗng (kiểm `pipefail`)
- [ ] Timer/cron 02:00 đã cài — `systemctl list-timers` hoặc `crontab -l` 📷📄

##### Restore
- [ ] `restore.sh -h` hoạt động; chỉ dùng bản do chính `backup.sh` tạo
- [ ] Đếm dòng bảng `todos` **trước** khi xóa: `N` dòng
- [ ] Xóa/hỏng dữ liệu (`DROP TABLE todos` hoặc `TRUNCATE`)
- [ ] Chạy restore → số dòng quay về `N`, nội dung giống cũ, app `GET /todos` đúng 📷
- [ ] **Restore thành công ≥3 lần liên tiếp** (không chỉ 1 lần may mắn)
- [ ] Restore cả nội dung web (đã xóa `index.html` → khôi phục lại)
- [ ] Restore từ bản **đã rsync sang VM2** cũng chạy được

##### Hiểu để trả lời
- [ ] Nếu 2 giờ sáng đĩa đầy thì script làm gì, ở dòng nào
- [ ] `pipefail` cứu gì trong `pg_dump | gzip`; không có thì sao
- [ ] Vì sao `appuser` không phải superuser; `pg_hba.conf` làm gì
- [ ] Vì sao backup có timestamp + retention; chọn 7 ngày vì sao
- [ ] Khôi phục DB ngay trước mặt thầy từ bản đã tạo trước đó (tập sẵn, bấm giờ)

### Người 5 — Bộ công cụ tự động hóa, cảnh báo
- `scripts/menu.sh`: menu tương tác gọi các công cụ, xử lý nhập sai.
- `scripts/deploy.sh`: copy app/site, chown/chmod, `nginx -t` → reload → kiểm tra (curl); lỗi thì **tự rollback** về bản tốt trước (giữ bản backup config).
- `scripts/healthcheck.sh`: CPU/RAM/disk theo ngưỡng (kiểm cả `/` và phân vùng `/data`), cổng lắng nghe (`ss`), trạng thái nginx/labapp/postgresql; vượt ngưỡng → log + mail.
- `scripts/logrotate.sh`: xoay + nén log chọn, giữ N, xóa cũ hơn.
- Cấu hình msmtp (Gmail app password hoặc thay thế) để gửi cảnh báo thật. **Phương án dự phòng khi demo mất mạng:** cài `mailutils` + MTA local (vd `postfix` chế độ local only) để lệnh `mail` gửi vào hộp thư của `sysadmin` và đọc bằng `mail`; `send_alert` thử msmtp trước, thất bại thì ghi log và dùng `mail` local. Đề chấp nhận lệnh `mail` hoặc msmtp.
- Deploy app: sau khi chép code, restart `labapp` an toàn (kiểm tra `/health` sau restart, lỗi thì rollback bản trước).
- Chạy shellcheck **toàn bộ script của cả nhóm** (cả của người 4), tổng hợp output sạch.
- Thư viện chung `scripts/lib.sh` (log, load config, alert) để người 4 có thể source.
- **Mock:** dùng service có sẵn (`ssh`, `cron`) để thử health-check; deploy thử với site nginx tĩnh.
- **Demo:** menu → từng công cụ; deploy cấu hình lỗi → rollback; dừng service → mail cảnh báo; shellcheck sạch.
- **Chuẩn bị trả lời:** `set -euo pipefail` thay đổi gì, đã cứu ở đâu; trap ERR/EXIT; cách chống reload lỗi.

#### Checklist hoàn thành — Người 5

##### Yêu cầu chung cho **mọi** script (kể cả của Người 4)
- [ ] Có shebang `#!/usr/bin/env bash` và chú thích đầu file
- [ ] Có `set -euo pipefail`
- [ ] Có `trap ... ERR` (và EXIT nếu cần)
- [ ] Có `-h/--help`; dùng `getopts` khi hợp lý
- [ ] Ghi log rõ đã làm gì
- [ ] **`shellcheck scripts/*.sh` không còn lỗi** (hoặc nêu cảnh báo còn lại + lý do) 📷

##### Từng công cụ
- [ ] `menu.sh`: chọn từng mục gọi đúng công cụ; **nhập sai** (chữ, số ngoài khoảng, rỗng) thì báo và hỏi lại, không thoát
- [ ] `deploy.sh`: chép app/site vào đúng chỗ, `chown`/`chmod` đúng, `nginx -t` → reload → xác nhận 📷
- [ ] `deploy.sh` với **config cố tình lỗi**: bắt được lỗi, **tự rollback** về bản tốt, site vẫn chạy 📷
- [ ] `deploy.sh` khi deploy app: restart `labapp`, kiểm `/health`, lỗi thì rollback
- [ ] `healthcheck.sh`: kiểm CPU, RAM, disk (`/` và `/data`), cổng lắng nghe, trạng thái nginx/labapp/postgresql
- [ ] Hạ ngưỡng giả để vượt ngưỡng → ghi log + gửi cảnh báo 📷
- [ ] **Dừng 1 service** (`systemctl stop nginx`) → healthcheck phát hiện + gửi mail 📷
- [ ] Mail cảnh báo **thực sự đến** hộp thư (msmtp hoặc `mail` local) 📷
- [ ] Phương án dự phòng mất mạng chạy được (mail local)
- [ ] `logrotate.sh`: xoay + nén 1 log, giữ N thế hệ, xóa thế hệ cũ hơn 📷
- [ ] `lib.sh`: Người 4 source được, log ghi vào `/var/log/labtools/`
- [ ] `labtools.conf` thay ngưỡng thì script đổi theo (không hard-code)
- [ ] Script cài vào `/opt/labtools/`; file cấu hình mẫu trong repo 📄

##### Hiểu để trả lời
- [ ] `set -euo pipefail` mỗi cờ làm gì; **một chỗ cụ thể nó đã cứu nhóm**
- [ ] `trap ERR` và `trap EXIT` khác nhau thế nào
- [ ] Quy trình test → reload → xác nhận → rollback hoạt động ra sao
- [ ] Healthcheck kiểm "trạng thái thật" khác gì chỉ kiểm tiến trình còn chạy
- [ ] Giải thích 1 cảnh báo shellcheck (nếu còn) và vì sao chấp nhận

## 3. Điểm tiếp xúc giữa các người (để làm độc lập vẫn khớp)

| Từ → Đến | Điểm nối | Đã chốt ở hợp đồng |
|---|---|---|
| 2 → 3 | Nginx proxy tới cổng app | 127.0.0.1:5000 |
| 3 → 4 | App kết nối DB | tên DB/user/biến env |
| 4 → 1 | Đĩa backup, rsync sang VM2 | `/data`, `/data/backup-recv`, SSH key |
| 5 → 2,3,4 | Health-check, deploy, backup | tên service, đường dẫn, `labtools.conf` |
| 4 ↔ 5 | `lib.sh`, log, alert | `/etc/labtools/labtools.conf` |
| 1 → tất cả | Mở cổng | 2222/80/443 |

Nếu ai cần đổi một giá trị trong hợp đồng: báo cả nhóm trước, sửa bảng ở Mục 1, rồi mới đổi.

## 4. Lịch trình (tổng 14 ngày)

Hai giai đoạn: **Giai đoạn A (ngày 1–7): mỗi người làm xong phần mình, chạy độc lập trên VM riêng (dùng mock).** **Giai đoạn B (ngày 8–14): ráp lại, test, viết báo cáo, tập demo, đóng gói.**

### Giai đoạn A — Làm riêng (ngày 1–7)

| Ngày | Cả nhóm | Người 1 | Người 2 | Người 3 | Người 4 | Người 5 |
|---|---|---|---|---|---|---|
| 1 | Chốt Mục 1, tạo repo Git, điền README | Dựng VM1/VM2 chuẩn, mạng, user, **giao `.ova`** | Import VM, cài Nginx, vhost app + status (proxy tới app giả) | Import VM, cài Node.js, khung Express: `/health`, `GET /todos` | Import VM, cài PostgreSQL, DB `appdb`, role `appuser`, listen localhost | Import VM, `lib.sh` + `labtools.conf` hoàn chỉnh |
| 2 | | Mount `/data` qua fstab, UFW, SSH hardening | Header proxy, TLS tự ký, HTTPS, 80 → 301 → 443 | `POST`, `PUT /todos`, `init.sql`, `index.html` | `init.sql` + dữ liệu mẫu, kiểm `ss`; `backup.sh`: dump + nén + timestamp | `healthcheck.sh`: CPU/RAM/disk, cổng, service, ngưỡng |
| 3 | | fail2ban SSH (ban thử), auditd (`passwd`, `shadow`) | Mở 443 UFW, test curl 2 vhost, lập luận tự ký vs Let's Encrypt | `labapp.service`, `app.env` 640, test kill app → systemd restart, `journalctl` | `backup.sh`: retention + rsync VM2; SSH key sang VM2 | msmtp + `send_alert`, test mail thật |
| 4 | | Lynis lần 1, sửa 3 mục | fail2ban jail nginx (nếu có login), tinh chỉnh | Dọn code, tự đọc lại để giải thích | `restore.sh` + kiểm toàn vẹn, test restore lần 1 | `deploy.sh`: copy, quyền, test → reload → xác nhận, rollback khi lỗi |
| 5 | | Sơ đồ VM, chụp ảnh bằng chứng | Chụp ảnh | Chụp ảnh | Timer/cron 02:00, test restore lần 2–3, chụp ảnh | `logrotate.sh`, `menu.sh` |
| 6 | Mỗi người **tự test phần mình lần cuối**, push, viết phần báo cáo của mình trong `report/`, soạn 3–5 câu vấn đáp | `report/01` | `report/02` | `report/03` | `report/04` | Chạy shellcheck toàn bộ, `report/05` |
| 7 | **Chốt phiên bản (tag Git `v1-rieng`)**. Mỗi người trình bày phần mình 10 phút cho cả nhóm | | | | | |

Quy tắc giai đoạn A: push ít nhất 1 lần/ngày, thấy lệch hợp đồng thì báo ngay, không tự đổi. Lịch này khá chặt; nếu ai bị kẹt ở mục nào thì báo trong ngày đó để người khác hỗ trợ.

### Giai đoạn B — Ráp và hoàn thiện (ngày 8–14)

| Ngày | Việc |
|---|---|
| 8 | **Ráp**: chọn 1 laptop làm máy chính, dựng VM1+VM2 từ `.ova`, pull repo, cài theo thứ tự ở Mục 5. Chạy luồng đầu-cuối: trình duyệt → Nginx → app → DB. |
| 9 | Sửa lỗi lệch giữa các phần (quyền file, đường dẫn, tên biến). Chạy `deploy.sh` + `healthcheck.sh` trên hệ thống thật. |
| 10 | Test backup → rsync → xóa dữ liệu → restore ≥3 lần trên hệ thống thật. Test thật fail2ban ban và auditd bắt truy cập. |
| 11 | Lynis lần cuối, shellcheck toàn bộ, chụp lại ảnh bằng chứng trên hệ thống đã ráp. |
| 12 | Hoàn thiện báo cáo PDF, README, gộp ảnh. **Hoán đổi: mỗi người giải thích lại phần của người khác.** |
| 13 | **Tập demo** đủ kịch bản 12–15 phút (bấm giờ), hỏi chéo câu vấn đáp mẫu của đề. Chụp snapshot VM tốt. |
| 14 | Đóng gói `MSSV1_MSSV2_….tar.gz`, kiểm tra giải nén sạch. Ngày đệm dự phòng; nên nộp sớm nếu xong, vì nộp trễ bị trừ điểm. |

## 5. Thứ tự ráp trên máy chính (ngày 8)

1. N1: VM1, VM2, mạng, fstab `/data`, user, SSH key, UFW.
2. N4: PostgreSQL + `appdb`/`appuser` + `init.sql`.
3. N3: app + `app.env` + `labapp.service`, test `curl 127.0.0.1:5000/todos`.
4. N2: Nginx vhost + TLS, test `curl -k https://app.lab.local/todos`.
5. N5: cài `/opt/labtools`, `labtools.conf`, msmtp; chạy healthcheck.
6. N4: backup đầu tiên + rsync sang VM2 + test restore.
7. N1: fail2ban, auditd, Lynis (làm sau cùng vì có thể ảnh hưởng dịch vụ).
8. Chạy kịch bản demo từ đầu đến cuối; chụp snapshot.

## 6. Quy tắc làm việc
- Không commit mật khẩu, private key. Chỉ commit file `.example`.
- Mỗi script có shebang, chú thích, `set -euo pipefail`, trap, `--help`, qua shellcheck.
- Commit thường xuyên, mỗi người chỉ sửa thư mục của mình; muốn sửa của người khác thì báo trước.
- Mỗi người ghi chú các câu hỏi vấn đáp tự đặt cho phần mình trong `report/`.

## 7. Checklist chung cả nhóm

Xem thêm bảng kiểm trang 10–11 của đề. Checklist từng người nằm ở cuối mục của người đó (Mục 2). Phần dưới do nhóm trưởng tổng hợp ở ngày 12–14.

### Hệ thống đã ráp
- [ ] Trình duyệt → `https://app.lab.local` → Nginx → app → DB → trả dữ liệu đúng
- [ ] Hai vhost đều phản hồi qua `curl -H "Host: ..."` từ máy Windows và VM2
- [ ] Reboot VM1: mọi dịch vụ tự lên, `/data` còn, app chạy
- [ ] Đã **chạy trọn kịch bản demo (Mục 8 của KEHOACH.md) ít nhất 2 lần**, bấm giờ ≤15 phút
- [ ] Đã chụp **snapshot** VM tốt cho cả VM1 và VM2

### Gói nộp
- [ ] Báo cáo PDF 6–12 trang (không kể phụ lục), có bảng phân công, sơ đồ VM, ảnh chú thích
- [ ] Toàn bộ script (giữ shebang, chú thích)
- [ ] Toàn bộ file cấu hình **thật** (Nginx, systemd, PostgreSQL, UFW, fail2ban, auditd)
- [ ] `README.md` đủ: hướng đồ án, sơ đồ VM, bảng phân công (có tên + MSSV), cách tái tạo
- [ ] Không có mật khẩu/private key trong gói — `grep -rniE "password|BEGIN .*PRIVATE" .` chỉ thấy file `.example`/tên biến
- [ ] File tên đúng mẫu `MSSV1_MSSV2_….tar.gz`, đã **giải nén thử ở thư mục sạch** và đủ file

### Vấn đáp chéo
- [ ] Mỗi người trả lời được ≥3 câu hỏi về phần của **người khác**
- [ ] Đã thử 5 câu mẫu trong đề (cổng, đường đi request, SSH, đĩa đầy, set -euo pipefail) — mỗi câu 1 người khác nhau trả lời
- [ ] Người 4 khôi phục DB trực tiếp trước cả nhóm mà không cần xem tài liệu

## 8. Kịch bản demo 12–15 phút (kèm phân vai)

Viết chi tiết từng lệnh vào `report/KICHBAN_DEMO.md` (ngày 12), tập bấm giờ ngày 13. Tổng thời gian dự kiến 13,5 phút + 1,5 phút dự phòng.

| Phút | Việc trình diễn | Người làm | Lệnh / chứng minh |
|---|---|---|---|
| 0:00–1:30 | Giới thiệu sơ đồ, trạng thái hệ thống | N1 | `ufw status verbose`, `systemctl status nginx labapp postgresql`, `hostname` |
| 1:30–3:30 | Luồng đầu-cuối + 2 vhost + HTTPS | N2 (+N3 thêm todo trên trình duyệt) | `curl -H "Host: ..."` cả 2 vhost, `curl -kI http://...` thấy 301, `curl -k https://...`, thêm 1 todo trên web |
| 3:30–4:30 | systemd tự khởi động lại + DB chỉ nghe localhost | N3 + N4 | `kill` app, `journalctl -u labapp`, `ss -tlnp \| grep 5432` |
| 4:30–6:30 | Bảo mật: ban fail2ban + auditd | N1 | tấn công từ VM2, `fail2ban-client status sshd`; `cat /etc/shadow` rồi `ausearch -k identity` |
| 6:30–9:30 | Backup → rsync → retention → xóa dữ liệu → restore | N4 | chạy backup, `ls` VM2, bản cũ bị xóa, `DROP`/xóa todo, restore, F5 trình duyệt thấy dữ liệu về |
| 9:30–11:00 | Deploy cấu hình lỗi → rollback | N5 | deploy conf nginx sai, `nginx -t` fail, tự rollback, site vẫn chạy |
| 11:00–12:30 | Health-check bắt lỗi + cảnh báo | N5 | `systemctl stop nginx`, chạy healthcheck, mail về |
| 12:30–13:30 | Menu + shellcheck sạch | N5 | `menu.sh`, `shellcheck scripts/*.sh` |
| 13:30–15:00 | Dự phòng / hỏi đáp nhanh | cả nhóm | |

**Trước giờ demo:** snapshot VM tốt; `fail2ban-client unban --all`; xóa dữ liệu demo cũ; kiểm tra có mạng nếu dùng msmtp (hoặc chuyển sang mail local); sạc laptop, tắt thông báo.

## 9. Báo cáo PDF: ai gộp, cấu trúc

- **Người gộp và xuất PDF: Người 1 (nhóm trưởng)**; ngày 12 chốt file, 6–12 trang không kể phụ lục.
- Cấu trúc theo đề: (1) Tổng quan hệ thống: hướng chọn, trình ảo hóa, sơ đồ VM, chế độ mạng, **bảng phân công 5 người ánh xạ lên 3 thành phần (Mục 3, 4, 5 của đề)**; (2) **Các bước xây dựng**: quyết định cấu hình then chốt, tham chiếu file cấu hình thật đã nộp; (3) Bảo mật; (4) Sao lưu & khôi phục; (5) Tự động hóa (kèm output shellcheck).
- Mỗi người, trong file `report/0X_*.md` của mình, viết đủ hai phần: **"Các bước xây dựng"** (quyết định then chốt) và nội dung chuyên mục; mọi khẳng định bảo mật, sao lưu, tự động hóa cần ảnh chụp có chú thích hoặc file cấu hình thật.
- **Gói nộp `MSSV1_MSSV2_….tar.gz`** phải có: báo cáo PDF; toàn bộ script (giữ shebang, chú thích); toàn bộ file cấu hình thật (Nginx, systemd unit, cấu hình PostgreSQL, luật UFW, fail2ban, auditd); `README.md` (hướng đồ án, sơ đồ VM, bảng phân công, cách tái tạo). Không đưa private key hoặc mật khẩu thật vào.
