-- =====================================================================
-- init.sql - Tạo bảng todos cho ứng dụng Todo list (Người 3)
-- Chạy bằng tài khoản quản trị (postgres) trên database appdb:
--     sudo -u postgres psql -d appdb < init.sql
-- Chạy lại nhiều lần KHÔNG lỗi nhờ "IF NOT EXISTS"; GRANT chạy lại cũng không sao.
-- =====================================================================

-- Bảng todos: mỗi dòng là một việc cần làm
CREATE TABLE IF NOT EXISTS todos (
    id         SERIAL PRIMARY KEY,                  -- số thứ tự tự tăng, không trùng
    title      VARCHAR(200) NOT NULL,               -- nội dung việc, tối đa 200 ký tự
    done       BOOLEAN NOT NULL DEFAULT FALSE,      -- đã xong chưa (mặc định: chưa)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()   -- thời điểm tạo, tự điền
);

-- Cấp quyền tối thiểu cho tài khoản của app (appuser):
-- được kết nối vào database appdb
GRANT CONNECT ON DATABASE appdb TO appuser;
-- chỉ được đọc, thêm, sửa bảng todos (KHÔNG có DELETE, DROP)
GRANT SELECT, INSERT, UPDATE ON TABLE todos TO appuser;
-- được dùng "máy phát số" của cột id để thêm dòng mới
GRANT USAGE, SELECT ON SEQUENCE todos_id_seq TO appuser;
