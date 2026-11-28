// =====================================================================
// server.js - Ứng dụng Todo list (Node.js + Express + PostgreSQL)
// Người 3 - Đồ án Linux. Chạy bằng: node server.js
// Khi chạy thật: nằm ở /opt/app, do systemd (labapp.service) khởi động.
// =====================================================================

// Nạp 2 thư viện đã cài bằng npm
const express = require('express');   // dựng web server
const { Pool } = require('pg');       // kết nối PostgreSQL

// ---------------------------------------------------------------------
// 1. Đọc cấu hình từ BIẾN MÔI TRƯỜNG (không ghi mật khẩu trong code)
//    systemd nạp các biến này từ file /etc/labapp/app.env
// ---------------------------------------------------------------------
const BIEN_BAT_BUOC = ['DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'];

for (const ten of BIEN_BAT_BUOC) {
  if (!process.env[ten]) {
    // Thiếu cấu hình thì dừng ngay, báo lỗi ra stderr (journald sẽ ghi lại)
    console.error(`[LỖI] Thiếu biến môi trường ${ten}. Kiểm tra /etc/labapp/app.env`);
    process.exit(1);
  }
}

// App chỉ nghe trên 127.0.0.1 (chính máy này), cổng 5000 - đúng hợp đồng nhóm.
// Người ngoài không gọi thẳng app được, phải đi qua Nginx (reverse proxy).
const HOST = '127.0.0.1';
const PORT = 5000;

// ---------------------------------------------------------------------
// 2. Tạo "bể kết nối" (pool) tới PostgreSQL
// ---------------------------------------------------------------------
const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT),        // biến môi trường luôn là chữ -> đổi sang số
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: 5,                                   // giữ tối đa 5 kết nối
  connectionTimeoutMillis: 3000             // chờ DB tối đa 3 giây rồi báo lỗi
});

// Nếu một kết nối đang rảnh trong pool bị đứt (vd DB khởi động lại) thì ghi log,
// không để app bị sập vì lỗi này.
pool.on('error', (err) => {
  console.error('[LỖI] Kết nối DB trong pool bị lỗi:', err.message);
});

// ---------------------------------------------------------------------
// 3. Tạo app Express và các bước xử lý chung
// ---------------------------------------------------------------------
const app = express();

// Cho phép đọc dữ liệu JSON mà trình duyệt gửi lên (dùng cho POST)
app.use(express.json());

// Ghi log MỖI yêu cầu ra stdout -> journald thu lại.
// X-Real-IP là header Nginx gửi kèm để báo IP thật của người dùng.
app.use((req, res, next) => {
  res.on('finish', () => {
    const ip = req.headers['x-real-ip'] || req.socket.remoteAddress;
    console.log(`${req.method} ${req.originalUrl} -> ${res.statusCode} (IP: ${ip})`);
  });
  next();
});

// Phục vụ giao diện web: các file trong thư mục public/ (index.html)
// 'public' là đường dẫn tương đối -> tính từ WorkingDirectory=/opt/app
app.use(express.static('public'));

// ---------------------------------------------------------------------
// 4. Các endpoint (ô cửa) của app
// ---------------------------------------------------------------------

// GET /health - kiểm tra sức khỏe: app sống VÀ nói chuyện được với DB
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');          // câu hỏi đơn giản nhất gửi tới DB
    res.status(200).json({ status: 'ok', db: 'ok' });
  } catch (err) {
    console.error('[LỖI] /health: không kết nối được DB:', err.message);
    res.status(503).json({ status: 'error', db: 'down' });
  }
});

// GET /todos - ĐỌC danh sách việc cần làm
app.get('/todos', async (req, res) => {
  try {
    const ketQua = await pool.query(
      'SELECT id, title, done, created_at FROM todos ORDER BY id'
    );
    res.json(ketQua.rows);                 // rows = mảng các dòng trong bảng
  } catch (err) {
    console.error('[LỖI] GET /todos:', err.message);
    res.status(500).json({ error: 'Lỗi máy chủ' });
  }
});

// POST /todos - GHI (thêm) một việc mới. Dữ liệu gửi lên: {"title": "..."}
app.post('/todos', async (req, res) => {
  const title = req.body && typeof req.body.title === 'string'
    ? req.body.title.trim()                // bỏ khoảng trắng thừa 2 đầu
    : '';

  // Kiểm tra dữ liệu đầu vào trước khi đưa vào DB
  if (title === '' || title.length > 200) {
    return res.status(400).json({ error: 'title phải có từ 1 đến 200 ký tự' });
  }

  try {
    // $1 là "chỗ trống" - pg tự điền title vào một cách an toàn.
    // Không ghép chuỗi trực tiếp -> chống tấn công SQL injection.
    const ketQua = await pool.query(
      'INSERT INTO todos (title) VALUES ($1) RETURNING id, title, done, created_at',
      [title]
    );
    console.log(`Đã thêm todo id=${ketQua.rows[0].id}`);
    res.status(201).json(ketQua.rows[0]);  // 201 = đã tạo mới
  } catch (err) {
    console.error('[LỖI] POST /todos:', err.message);
    res.status(500).json({ error: 'Lỗi máy chủ' });
  }
});

// PUT /todos/:id - đánh dấu một việc là ĐÃ XONG
app.put('/todos/:id', async (req, res) => {
  const id = Number(req.params.id);        // :id lấy từ đường dẫn, vd /todos/3 -> 3

  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: 'id phải là số nguyên dương' });
  }

  try {
    const ketQua = await pool.query(
      'UPDATE todos SET done = TRUE WHERE id = $1 RETURNING id, title, done, created_at',
      [id]
    );
    if (ketQua.rowCount === 0) {           // không có dòng nào bị sửa -> id không tồn tại
      return res.status(404).json({ error: 'Không tìm thấy todo' });
    }
    console.log(`Đã đánh dấu xong todo id=${id}`);
    res.json(ketQua.rows[0]);
  } catch (err) {
    console.error('[LỖI] PUT /todos:', err.message);
    res.status(500).json({ error: 'Lỗi máy chủ' });
  }
});

// ---------------------------------------------------------------------
// 5. Bắt đầu lắng nghe
// ---------------------------------------------------------------------
app.listen(PORT, HOST, () => {
  console.log(`labapp đang chạy tại http://${HOST}:${PORT}`);
  console.log(`Kết nối DB ${process.env.DB_NAME} tại ${process.env.DB_HOST}:${process.env.DB_PORT} bằng user ${process.env.DB_USER}`);
});
