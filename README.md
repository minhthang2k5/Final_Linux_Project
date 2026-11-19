# Đồ án Linux — Hệ thống web + CSDL + vận hành tự động

> Hệ điều hành Linux & Ứng dụng — ĐHQG-HCM, ĐH Khoa học Tự nhiên.
> Chi tiết phân công và lịch làm việc: xem [KEHOACH.md](KEHOACH.md). Checklist kiểm tra hoàn thành từng người nằm ngay trong KEHOACH.md (Mục 2) và Mục 7.

## 1. Hướng đồ án đã chọn
Hệ thống hợp nhất: Nginx (reverse proxy, 2 vhost, HTTPS tự ký) → Express app (Node.js, systemd) → PostgreSQL (chỉ localhost), vận hành bằng bộ công cụ Bash (deploy, backup, restore, health-check, xoay log), sao lưu rsync sang VM2.

Trình ảo hóa: VirtualBox. Hệ điều hành: Ubuntu 22.04 LTS Server.

## 2. Sơ đồ VM

```
Client ──HTTPS──> VM1 web01 (192.168.56.10)
                   Nginx ──> Express (127.0.0.1:5000) ──> PostgreSQL (127.0.0.1:5432)
                   Bộ công cụ Bash (/opt/labtools)
                       │ rsync (SSH)
                       v
                  VM2 backup01 (192.168.56.20)  /data/backup-recv
```

<!-- TODO (Người 1): thay bằng sơ đồ chính thức + chế độ mạng NAT/Host-Only -->

## 3. Bảng phân công

| # | Thành viên | MSSV | Vai trò | Thư mục phụ trách |
|---|---|---|---|---|
| 1 | Minh Thắng | _TODO_ | Hạ tầng, mạng, gia cố hệ thống | `configs/ssh ufw fail2ban auditd` |
| 2 | _TODO_ | _TODO_ | Nginx, vhost, TLS | `configs/nginx tls` |
| 3 | _TODO_ | _TODO_ | Ứng dụng & systemd | `app/`, `configs/systemd` |
| 4 | _TODO_ | _TODO_ | CSDL & sao lưu/khôi phục | `configs/postgres`, `scripts/backup.sh restore.sh` |
| 5 | _TODO_ | _TODO_ | Bộ công cụ tự động hóa & cảnh báo | `scripts/` (menu, deploy, healthcheck, logrotate, lib), `configs/labtools` |

Ánh xạ lên ba thành phần của đề:

| Thành phần | Người |
|---|---|
| TP1 — Hạ tầng, Web & Bảo mật (Mục 3) | Người 1, Người 2 |
| TP2 — Ứng dụng & CSDL (Mục 4) | Người 3, Người 4 (phần CSDL) |
| TP3 — Vận hành & Tự động hóa (Mục 5) | Người 4 (backup/restore), Người 5 |

## 4. Cấu trúc repo

```
.
├── app/                 # Express app + public/index.html (HTML/JS thuần) + init.sql                    (Người 3)
├── configs/
│   ├── nginx/           # vhost, proxy, TLS                         (Người 2)
│   ├── tls/             # script tạo cert (KHÔNG commit key)        (Người 2)
│   ├── ssh/             # sshd_config                               (Người 1)
│   ├── ufw/             # luật UFW                                  (Người 1)
│   ├── fail2ban/        # jail.local                                (Người 1)
│   ├── auditd/          # audit rules                               (Người 1)
│   ├── systemd/         # labapp.service, backup.timer              (Người 3, 4)
│   ├── postgres/        # postgresql.conf, pg_hba.conf             (Người 4)
│   └── labtools/        # labtools.conf.example                     (Người 5)
├── scripts/             # toàn bộ script Bash
│   ├── _template.sh     # mẫu script chuẩn (copy khi viết script mới)
│   └── lib.sh           # hàm dùng chung: log, load config, alert
├── report/              # nháp báo cáo + ảnh bằng chứng (images/)
├── KEHOACH.md           # kế hoạch & hợp đồng chung
└── README.md
```

## 5. Hợp đồng chung
Bảng giá trị cố định (IP, cổng, tên DB, đường dẫn…) nằm ở **Mục 1 của [KEHOACH.md](KEHOACH.md)**. Không tự đổi; muốn đổi thì báo cả nhóm và sửa bảng đó trước.

## 6. Cách tái tạo hệ thống
<!-- TODO: cả nhóm điền sau khi ráp xong. Thứ tự gợi ý: -->
1. Tạo VM1 (`web01`) và VM2 (`backup01`) từ Ubuntu 22.04 Server, mạng NAT + Host-Only.
2. Cài gói, mount `/data`, cấu hình user/SSH/UFW (Người 1).
3. Cài PostgreSQL, tạo DB/role (Người 4).
4. Triển khai app + service systemd (Người 3).
5. Cài Nginx + TLS (Người 2).
6. Cài bộ công cụ vào `/opt/labtools`, cấu hình msmtp (Người 5).
7. Chạy backup đầu tiên, kiểm tra restore.
8. Bật fail2ban, auditd, chạy Lynis (Người 1).

## 7. Quy tắc làm việc
- Không commit mật khẩu / private key; chỉ commit file `*.example`.
- Mọi script: shebang, chú thích, `set -euo pipefail`, `trap` ERR, `--help`, qua `shellcheck` sạch (xem `scripts/_template.sh`).
- Mỗi người chỉ sửa thư mục của mình; muốn sửa của người khác thì báo trước.
- Push ít nhất 1 lần/ngày.
