# Báo cáo kỹ thuật

Mỗi người viết phần mình dưới dạng file `.md` riêng (nháp), cuối cùng gộp thành 1 file PDF 6–12 trang.

| File | Người | Nội dung |
|---|---|---|
| `01_tong_quan_ha_tang.md` | 1 | Tổng quan, sơ đồ VM, mạng, UFW, SSH, fail2ban, auditd, Lynis |
| `02_nginx_tls.md` | 2 | Nginx, vhost, header, TLS tự ký + lập luận không dùng Let's Encrypt |
| `03_app_systemd.md` | 3 | App, systemd, EnvironmentFile (kèm `ls -l`) |
| `04_csdl_sao_luu.md` | 4 | CSDL, backup, retention, lịch, quy trình restore + bằng chứng |
| `05_tu_dong_hoa.md` | 5 | Từng script: mục đích, tham số, xử lý lỗi, cảnh báo, kết quả shellcheck |

Ảnh bằng chứng đặt trong `images/`, đặt tên `<nguoi>_<noi-dung>.png` (vd: `n1_fail2ban-ban.png`).
Mỗi file nên kèm 3–5 câu hỏi vấn đáp tự đặt cho phần của mình.
