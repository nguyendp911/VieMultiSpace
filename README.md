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


## MultiSpace Sync — điều khiển theo nhóm

Vào ứng dụng > **MultiSpace Sync**, chọn không gian (có Chọn tất cả / Bỏ chọn).
- **Mở URL**: chỉ nhận HTTPS, mở theo hàng đợi **từng không gian một**, mỗi phiên có WKWebsiteDataStore riêng.
- **Nạp lại**: tải lại liên kết nhóm cuối cùng đã nạp thành công hoặc URL trang chủ.
- **Trạng thái**: Đang chờ, Đang tải, Đã nạp, Thất bại, Đã dừng; có thể dừng.
- **Xem trước**: WKWebView thực đang tải được gắn vào khung xem trước; thời gian chờ 40 giây/không gian.
- **Mở thủ công**: sau khi lệnh nhóm hoàn thành, khi mở từng không gian sẽ ưu tiên tải URL nhóm gần nhất.
- Khi app vào nền, hàng đợi sẽ dừng; các phiên/chứng thực vẫn được tách độc lập.

Lệnh này không đồng bộ cử chỉ và không tự động tương tác trên Facebook. "Đã nạp" là nạp xong tài liệu web, không có nghĩa website chấp nhận đăng nhập. Ứng dụng vẫn cần kiểm thử thực tế trên iPhone.


## Vie Account Center (giao diện quản lý tài khoản)

Mở **Trung tâm tài khoản** ở trang chính:

- Tìm kiếm tài khoản, lọc Facebook/website khác, mở phiên đăng nhập riêng.
- Tạo nhanh 1–50 không gian trống; đặt tên Facebook 01, Facebook 02…
- Xóa dữ liệu web của một không gian mà không ảnh hưởng không gian khác.
- Đăng nhập, nhập 2FA trực tiếp trên trang web chính thức; không đưa thông tin đăng nhập vào biểu mẫu trung tâm.
- WebKit lưu riêng từng phiên; app không xuất/đọc giá trị cookie, token, mật khẩu hoặc seed TOTP.

Chức năng này **không chạy file Python trên iPhone**, và không tích hợp các API Facebook không công khai để lấy/chuyển đổi token. Đừng upload file Python có mật khẩu hoặc mã 2FA lên GitHub public. Nếu đã vô tình chia sẻ, đổi mật khẩu và xoay vòng 2FA.


## Native Swift login và TOTP

Phần lưu thông tin đăng nhập theo từng không gian và tạo mã TOTP 6 chữ số (chu kỳ 30 giây) đã được viết bằng Swift + CryptoKit + iOS Keychain; không cần runtime Python.

Vào Trung tâm tài khoản > menu (...) > Lưu mật khẩu và 2FA. Trong trình duyệt Facebook, bấm Điền đăng nhập để điền vào biểu mẫu HTTPS facebook.com; ứng dụng không tự bấm Đăng nhập. Nút Mã 2FA tạo mã sau khi xác thực người dùng. Mỗi tài khoản lưu trong Keychain theo UUID và yêu cầu xác thực bằng thiết bị khi đọc.

Không tích hợp API Facebook không công khai, giả lập thiết bị Android, chuyển đổi access token hoặc trích xuất cookie/token. Không đưa dữ liệu nhạy cảm trong file Python lên GitHub.
