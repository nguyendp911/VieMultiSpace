# Vie MultiSpace (iOS 17+)

Đây là dự án **độc lập** nằm trong repository HanziLock. Không sửa App/, Shared/, Widget/, project.yml hoặc workflow build.yml ở gốc.

## Công dụng

- Tạo nhiều không gian Facebook, Instagram, TikTok, X hoặc website HTTPS.
- Mỗi không gian có UUID và WKWebsiteDataStore riêng: cookie, local storage, cache lưu tách biệt trên máy.
- Mở, đổi tên, xóa từng không gian; xóa cookie/đăng xuất không gian.
- Có tùy chọn khóa giao diện bằng Face ID hoặc mã khóa iPhone.
- Không có API bên ngoài, không gửi mật khẩu hoặc cookie lên máy chủ.

**Quan trọng:** Đây là nhiều *phiên web* độc lập, KHÔNG phải nhân bản ứng dụng Facebook gốc hay các app khác. Một số website có thể giới hạn đăng nhập từ WKWebView hoặc không hỗ trợ đủ chức năng như app gốc.

## Build IPA trên GitHub (Windows)

1. Vào tab Actions của repository.
2. Chọn **Build Vie MultiSpace IPA** rồi bấm **Run workflow**, hoặc xem lần build tự động khi cập nhật thư mục VieMultiSpace.
3. Sau khi job thành công, mở mục Artifacts, tải **VieMultiSpace-unsigned-ipa**.
4. Giải nén để có **VieMultiSpace-unsigned.ipa**.
5. Dùng Sideloadly trên Windows để ký và cài vào iPhone bằng Apple ID cá nhân. IPA tạo bởi Actions chưa được ký để cài trực tiếp.

Apple ID miễn phí thường cần gia hạn 7 ngày. Bản build chưa có xác nhận chạy trên iPhone thực tế.

## Build trên Mac (nếu có)

cd VieMultiSpace
brew install xcodegen
xcodegen generate
open VieMultiSpace.xcodeproj

Bundle ID là vn.vie.multispace, độc lập với HanziLock. Hãy giữ nguyên Bundle ID khi cập nhật để tránh mất dữ liệu.

Không lưu mật khẩu trong mã nguồn, không đưa chứng chỉ .p12 hoặc tài khoản Apple ID lên repository công khai.
