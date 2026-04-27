# 🚀 Auto Setup Minecraft FRP Tunnel (V15.0)

Giải pháp quản lý **FRP (Fast Reverse Proxy)** chuyên sâu cho hệ thống Minecraft Hosting (VPS + Mini PC). Phiên bản **V15.0** mang đến bước nhảy vọt về kiến trúc cô lập người dùng và bảo mật hệ thống.

> [!IMPORTANT]
> **V15.0 - Kiến trúc Per-User Core**: Mỗi người dùng "IP Riêng" giờ đây có một tiến trình `frps` hoàn toàn độc lập, đảm bảo hiệu suất tối đa và bảo mật tuyệt đối.

---

## ✨ Tính năng vượt trội (V15.0)

### 🏗️ Kiến trúc & Hiệu quả
-   🔥 **DEDICATED IP MODE**: Tự động tạo instance `frps` riêng cho mỗi user, bind trực tiếp vào IP tĩnh được chỉ định. Cô lập hoàn toàn traffic giữa các người dùng.
-   🔒 **Bảo mật chuyên sâu**: 
    -   Loại bỏ hoàn toàn rủi ro Arbitrary Code Execution (không dùng `source`).
    -   Tự động áp quyền `chmod 600` cho mọi file cấu hình chứa Token.
    -   Masking nhạy cảm: Ẩn Token khi hiển thị trên terminal.
-   ⚡ **Robustness**: Hệ thống chống treo loop (Loop Guard), kiểm soát lỗi logic và bảo vệ script trước các tình huống crash do `set -euo pipefail`.

### 🎮 Minecraft Specialized
-   ✅ **Hỗ trợ Dual-Stack**: Tự động cấu hình TCP và UDP đồng thời cho mọi port.
-   ✅ **Proxy Protocol v2**: Tích hợp sẵn cho BungeeCord/Velocity trên các gói IP Riêng.
-   ✅ **Firewall Cleanup**: Tự động quét và đóng toàn bộ các port tương ứng khi xóa user.
-   ✅ **Config Verification**: Tự động kiểm tra tính hợp lệ của cấu hình (`frpc verify`) trước khi khởi chạy service.

---

## 🛠️ Cài đặt nhanh

Sử dụng lệnh sau trên cả **VPS** và **Mini PC**:

```bash
curl -sL https://raw.githubusercontent.com/anlongawf/reverse-proxy/main/setup_frp.sh -o setup_frp.sh && sudo bash setup_frp.sh
```

---

## 📖 Hướng dẫn sử dụng

### 1. Trên VPS (Quản lý Server)
1.  Chạy script, chọn **Option 1** để cài đặt bộ lõi và cấu hình Master.
2.  Dùng **Option 2** để tạo User mới với **IP Riêng** (Dành cho các server lớn, cần dùng BungeeCord/Velocity).
3.  Dùng **Option 3** để tạo User mới dùng **IP Chung** (Dành cho server nhỏ, tiết kiệm tài nguyên).

### 2. Trên Mini PC (Local Node)
1.  Copy file cấu hình `frpc-user-USERNAME.toml` từ VPS sang thư mục `/etc/frp/` của Mini PC.
2.  Chạy script, chọn **Option 4**.
3.  Chọn user tương ứng để tự động tạo Systemd Service và khởi chạy Tunnel.

---

## 📋 So sánh các gói dịch vụ

| Tính năng | IP Riêng (Dedicated) | IP Chung (Shared) |
| :--- | :--- | :--- |
| **Instance FRP** | Riêng biệt (Process độc lập) | Dùng chung Master |
| **IP Kết nối** | IP Tĩnh riêng của User | IP chính của VPS |
| **Port Game** | Tự do chọn (vd: 25565) | Port ngẫu nhiên (vd: 19xxx) |
| **Proxy Protocol v2** | Hỗ trợ đầy đủ | Không hỗ trợ |
| **Độ ổn định** | Cao nhất (Cô lập hoàn toàn) | Khá (Phụ thuộc Master) |

---

## 🧹 Quản lý hệ thống

-   **Xem danh sách**: Chọn **Option 5** để theo dõi trạng thái sống/chết của từng user.
-   **Restart nhanh**: Chọn **Option 6** để khởi động lại service của 1 user hoặc toàn bộ hệ thống.
-   **Xóa User**: Chọn **Option 7**, script sẽ tự động dọn sạch Service, Config và đóng Firewall Ports.
-   **Xóa sạch**: Chọn **Option 8** nếu bạn muốn reset toàn bộ môi trường FRP.

---

## ⚠️ Lưu ý kỹ thuật
-   **Quyền Root**: Script yêu cầu quyền `sudo` để can thiệp vào `/etc/` và `systemd`.
-   **Port < 1024**: Cần quyền root trên Mini PC để bind các port đặc biệt này.
-   **IP Tĩnh**: Khi dùng gói IP Riêng, hãy đảm bảo IP đó đã được cấu hình trên Network Interface của VPS.

---
*Phát triển bởi anlongawf - Optimized for High-Performance Minecraft Hosting*
