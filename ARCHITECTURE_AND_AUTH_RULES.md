# Quy tắc kiến trúc Đăng nhập, 2FA & Trích xuất Token (Vie MultiSpace)

> **LƯU Ý BẢO VỆ TOÀN VẸN (CRITICAL ARCHITECTURE RULES)**:
> Tài liệu này chuẩn hóa toàn bộ cơ chế xác thực API, giả lập Android FB4A, xử lý 2FA và trích xuất Access Token trong ứng dụng Vie MultiSpace. Bất kỳ chức năng mới nào trong tương lai **tuyệt đối không được sửa đổi, làm suy giảm hoặc xóa bỏ** các luồng cốt lõi dưới đây.

---

## 1. Chuẩn Đăng nhập API & Giả lập Thiết bị Android (FB4A)

Tất cả các lệnh gọi API xác thực Facebook đều tuân thủ chặt chẽ theo đặc tả từ `1767528775-Login2FaConvertToken.py`:

1. **Header chuẩn 100%**:
   - Sử dụng `FacebookAPILoginClient.baseHeaders` chứa toàn bộ 17 header chữ thường y hệt Python script (`x-fb-net-hni`, `x-fb-sim-hni`, `x-fb-connection-quality`, `x-tigon-is-retry`, `priority: u=3,i`, `x-fb-http-engine: Liger`, `x-fb-request-analytics-tags`...).
   - Bổ sung header HTTP tiêu chuẩn (`User-Agent: Dalvik/2.1.0 ... [FBAN/FB4A]`, `Accept`, `Accept-Encoding`, `Connection: keep-alive`).

2. **Duy trì Cookie phiên xuyên suốt (SessionClient)**:
   - `SessionClient` đóng vai trò tương đương `requests.Session()`: thu thập `Set-Cookie` kể cả khi máy chủ trả mã lỗi 400/401 khi đòi 2FA.
   - Luôn mang `datr` và cookie thu thập được sang bước xác thực 2FA.

3. **Giả lập phần cứng Android khi gửi mã 2FA (`data2FA`)**:
   - **Bắt buộc**: Request gửi mã 2FA phải gửi **đầy đủ 100% thông số thiết bị Android** giống Request 1:
     - `adid`, `device_id`, `family_device_id`, `secure_family_device_id`
     - `sim_serials`, `client_country_code: "VN"`
     - `api_key`, `sig`, `cpl: "true"`, `try_num: "1"`
     - `fb_api_caller_class: "Fb4aAuthHandler"`, `fb_api_req_friendly_name: "authenticate"`
     - `meta_inf_fbmeta: "V2_UNTAGGED"`, `currently_logged_in_userid: "0"`
   - **Cơ chế Fallback**: Nếu payload đầy đủ bị Facebook từ chối do xung đột phiên bản, tự động thử lại ngay với payload tối giản (`minimalData2FA`).

---

## 2. Chuẩn Trích xuất Token từ Trình duyệt Web (Space WebView) & Cookie

Để giải quyết triệt để lỗi "trích xuất chỉ lấy được cookie, không lấy được token":

1. **Bóc tách CSRF Token (`fb_dtsg`)**:
   - Khi chạy trong WebView: đọc trực tiếp qua `window.require('DTSGInitialData').token` hoặc `window.require('DTSGInitData').token` hoặc input form `name="fb_dtsg"` hoặc regex HTML.
   - Khi chạy từ Cookie string: GET `https://m.facebook.com/me` hoặc `https://www.facebook.com/` để trích xuất `fb_dtsg`.

2. **Xác thực qua OAuth Confirm Endpoint (`/v1.0/dialog/oauth/confirm`)**:
   - POST tới `https://www.facebook.com/v1.0/dialog/oauth/confirm` (và `https://m.facebook.com/v1.0/dialog/oauth/confirm`) với:
     - `fb_dtsg`
     - `app_id`: `165907476854626` (Pages / Graph Explorer), `350685531728` (Android), `124024574287414` (Instagram), `438142079694454` (Ads)
     - `redirect_uri: fbconnect://success`
     - `return_format: access_token`
     - `display: popup`
     - `from_post: 1`
     - `__CONFIRM__: 1`
   - Dùng `NoRedirectDelegate` để chặn chuyển hướng và bắt mã token tại HTTP 302 Header `Location: fbconnect://success#access_token=EAAB...`.
   - **Tuyệt đối không dùng endpoint cũ** như `v2.3/dialog/oauth` (đã bị Meta khai tử).

3. **Fallback qua Ads Manager & Business Manager**:
   - Quét mã token nhúng tại `https://adsmanager.facebook.com/adsmanager/manage/campaigns` (`"accessToken":"EAAB..."`) và `https://business.facebook.com/content_management` (`"accessToken":"EAAG..."`).

---

## 3. Chuyển đổi 6 App Token (`FacebookAppTokens.convertAllTokens`)

Bất kể token gốc lấy được là `EAAB...` (Web/Ads) hay `EAAAAU...` (Android):
- Tự động gọi API `https://api.facebook.com/method/auth.getSessionforApp` để tạo trọn bộ 6 Token:
  1. `FB_ANDROID` (`350685531728` -> Token `EAAAAU...`)
  2. `MESSENGER_ANDROID` (`256002347743983`)
  3. `FB_LITE` (`275254692598279` -> Token `EAAD6V7...`)
  4. `MESSENGER_LITE` (`200424423651082`)
  5. `ADS_MANAGER_ANDROID` (`438142079694454`)
  6. `PAGES_MANAGER_ANDROID` (`121876164619130`)
- Lưu trữ an toàn trong iOS Keychain (`SpaceTokenVault`) gắn với từng không gian (`space.id`).

---

## 4. Tự động hóa trong Không gian (Space WebView)

1. **Auto-Extract Hook (`IsolatedWebView.Coordinator.webView(_:didFinish:)`)**:
   - Khi WebView tải xong trang trên `facebook.com`, nếu phát hiện cookie `c_user` và không gian chưa có token hợp lệ:
   - Tự động chạy ngầm `WebCookieBridge.extractTokenAndSave(for: space, webView: webView)`.
   - Người dùng đăng nhập (hoặc xác thực 2FA) trên web xong là token đã được tự động lưu vào Keychain mà không cần thao tác thủ công.

2. **Nút "Lấy Token" trực tiếp**:
   - Nằm ngay trên thanh công cụ `SecureLoginControls` dưới đáy màn hình của mỗi không gian.
   - Bấm vào sẽ kích hoạt quét ngay lập tức và hiển thị thông báo kết quả.

---

## 5. Phòng chống lỗi Malformed Token (Code 190) trong Smart Post

- Trước khi thực hiện đăng bài (hoặc tải ảnh lên nhóm/trang/cá nhân):
  - Luôn đi qua hàm làm sạch chuỗi `cleanAccessToken`.
  - Luôn sử dụng `SmartPostAPIClient.validateAccessToken` để kiểm tra tính hợp lệ trước khi gửi dữ liệu.
  - Ưu tiên chọn `FB_ANDROID` hoặc User Token có quyền hạn đăng bài.
