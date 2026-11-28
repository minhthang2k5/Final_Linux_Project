-- N4: lược đồ appdb theo hợp đồng (bảng todos). Chạy bằng user postgres qua setup-db.sh,
-- chạy lại nhiều lần không lỗi. Bảng thuộc postgres; appuser chỉ được cấp đúng quyền cần.
-- app/init.sql của Người 3 phải tạo bảng giống hệt (CREATE TABLE IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS todos (
    id         SERIAL PRIMARY KEY,
    title      TEXT        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    done       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Không ai (kể cả appuser) được tạo bảng mới trong schema public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO appuser;

-- Quyền tối thiểu cho app: đọc, thêm, sửa, xóa todo; dùng sequence để sinh id.
GRANT SELECT, INSERT, UPDATE, DELETE ON todos TO appuser;
GRANT USAGE, SELECT ON SEQUENCE todos_id_seq TO appuser;
