# Lọc Tin — hướng dẫn cài đặt (khoảng 10 phút, miễn phí)

Tool sẽ chạy trên GitHub: cứ khoảng 30 phút GitHub tự lấy tin mới từ các báo và đăng lên một trang web riêng của bạn,
dạng `https://<tên-github>.github.io/loc-tin/`. Bạn mở link đó trên điện thoại hoặc máy tính, ở đâu cũng được.
Máy tính của bạn **không cần bật**.

## Các file
| File | Tác dụng |
|---|---|
| `sources.json` | Danh sách nguồn tin. Muốn thêm hay bớt báo thì sửa ở đây |
| `fetch-news.ps1` | Script lấy tin, gộp tin trùng và chấm độ "nóng" |
| `site/index.html` | Trang đọc tin |
| `.github/workflows/cap-nhat-tin.yml` | Lịch tự chạy 30 phút một lần |

## Bước 1 — Tạo tài khoản và kho chứa (repository)
1. Vào https://github.com và đăng ký tài khoản (nếu chưa có).
2. Bấm **+** (góc trên bên phải), chọn **New repository**.
3. Đặt tên `loc-tin`, chọn **Public**, rồi bấm **Create repository**.

## Bước 2 — Tải các file lên
1. Trong repo vừa tạo, bấm **uploading an existing file**.
2. Kéo thả vào: `sources.json`, `fetch-news.ps1`, `HUONG-DAN.md` và **cả thư mục `site`**. Bấm **Commit changes**.
3. Tạo file lịch chạy: bấm **Add file → Create new file**, gõ tên đúng như sau (dấu `/` sẽ tự tạo thư mục):
   `.github/workflows/cap-nhat-tin.yml`
   Mở file `cap-nhat-tin.yml` trên máy bằng Notepad, copy toàn bộ nội dung, dán vào ô soạn thảo, rồi bấm **Commit changes**.

## Bước 3 — Bật quyền và chạy lần đầu
1. Vào **Settings → Actions → General**. Ở mục *Workflow permissions*, chọn **Read and write permissions** rồi bấm **Save**.
2. Vào tab **Actions**, chọn **Cap nhat tin** ở cột trái, bấm **Run workflow**. Đợi khoảng 1 phút đến khi hiện dấu ✅ xanh.

## Bước 4 — Bật trang web
1. Vào **Settings → Pages**.
2. Ở *Source* chọn **Deploy from a branch**, *Branch* chọn **gh-pages** và **/ (root)**, rồi bấm **Save**.
3. Đợi 1–2 phút, link trang của bạn sẽ hiện ở đầu trang đó.

## Dùng trên điện thoại như một app
- **iPhone (Safari):** mở link, bấm nút Chia sẻ, chọn **Thêm vào MH chính**.
- **Android (Chrome):** mở link, bấm ⋮, chọn **Thêm vào màn hình chính**.

## Cách dùng
- **Nóng**: những sự kiện có từ 2 nguồn trở lên cùng đưa tin, nhiều nguồn nhất xếp trước.
- **Mới nhất**: tất cả tin, mỗi sự kiện chỉ hiện một lần. Bấm "+ N bài cùng sự kiện" để xem các báo khác viết gì.
- **Theo dõi**: tin chứa từ khóa bạn đặt ở tab Cài đặt (không cần gõ dấu).
- **Xu hướng**: những từ khóa người Việt đang tìm nhiều nhất trên Google, kèm bài báo liên quan.
- **Cài đặt**: thêm từ khóa theo dõi, từ khóa chặn (ẩn tin), xem tình trạng từng nguồn tin.
- Bấm vào tên báo ở hàng nút trên cùng để tắt hoặc bật nguồn đó.

> Lưu ý: từ khóa và danh sách tin đã đọc được lưu **riêng trên từng thiết bị**. Bạn cần nhập từ khóa một lần trên điện thoại và một lần trên máy tính.

## Lưu ý khác
- Nếu repo không có hoạt động nào trong 60 ngày, GitHub có thể tự tắt lịch chạy và gửi email báo. Khi đó chỉ cần vào tab Actions bấm bật lại.
- Thêm báo: thêm một dòng vào `sources.json` với `name`, `url` (link RSS) và `"group": "vn"`.
- **Threads, Facebook** không cho lấy tin tự động (không có RSS hay API công khai). Vì vậy tool dùng Google News (tin nổi bật)
  và Google Trends (xu hướng tìm kiếm) để bắt các chủ đề đang hot trên mạng.
