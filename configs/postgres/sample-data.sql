-- N4: dữ liệu mẫu để demo backup/restore. Chỉ thêm khi bảng đang rỗng (chạy lại không nhân đôi).
INSERT INTO todos (title, done)
SELECT v.title, v.done
FROM (VALUES
    ('Cài PostgreSQL và tạo appdb',      TRUE),
    ('Viết backup.sh',                   TRUE),
    ('Rsync bản backup sang backup01',   FALSE),
    ('Tập restore trước mặt thầy',       FALSE),
    ('Kiểm tra ss -tlnp | grep 5432',    TRUE)
) AS v(title, done)
WHERE NOT EXISTS (SELECT 1 FROM todos);
