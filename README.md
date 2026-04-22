# 🚀 Auto Setup Minecraft FRP Tunnel (V13.0)

Giải pháp tự động hóa cài đặt và cấu hình **FRP (Fast Reverse Proxy)** tối ưu cho Server Minecraft. Giúp kết nối Server từ máy cá nhân (Home PC) hoặc Node nội bộ ra Internet thông qua VPS một cách nhanh chóng, bảo mật và ổn định.

> [!IMPORTANT]
> Hỗ trợ đầy đủ cho cả **Minecraft Java (TCP)** và **Minecraft Bedrock (UDP)**.
> Tích hợp sẵn **Proxy Protocol v2** để giữ nguyên IP người chơi khi dùng BungeeCord/Velocity.

---

## ✨ Tính năng nổi bật

-   ✅ **Tự động hóa 100%**: Tự nhận diện kiến trúc CPU (amd64/arm64), tải bản FRP mới nhất.
-   ✅ **Hỗ trợ Dual-Stack**: Tự động cấu hình TCP và UDP cho mỗi port (chơi được cả Java & Bedrock).
-   ✅ **Dummy IP System**: Tạo IP ảo trên loopback để cô lập traffic, tránh xung đột port hệ thống.
-   ✅ **Hot-Reload**: Thêm/Xóa port client mà không cần restart service, không làm rớt player đang online.
-   ✅ **Firewall Automation**: Tự động mở port trên UFW, Firewalld hoặc iptables.
-   ✅ **An toàn**: Token được ẩn khi nhập, cấu hình lưu trữ chuẩn `/etc/frp/`.

---

## 🛠️ Hướng dẫn cài đặt nhanh

Chạy lệnh duy nhất sau trên cả **VPS (Server)** và **Node (Client)**:

```bash
curl -sL https://raw.githubusercontent.com/anlongawf/reverse-proxy/main/setup_frp.sh -o setup_frp.sh && sudo bash setup_frp.sh
```

---

## 📖 Hướng dẫn chi tiết từng bước

### Bước 1: Cài đặt FRP Server (Trên VPS)
Đây là máy chủ trung gian có IP công khai.

1.  Mở script và chọn **Option 1** (`Cài đặt FRP SERVER`).
2.  **Chọn IP**: Script sẽ liệt kê các IP hiện có, chọn IP Public của VPS.
3.  **Control Port**: Mặc định là `7000`. Đây là port để Client kết nối tới.
4.  **Auth Token**: Nhập mật khẩu bảo mật (sẽ được ẩn khi nhập).
5.  **Hoàn tất**: Script tự động cài Core, tạo Service và mở Firewall port 7000.

### Bước 2: Cài đặt FRP Client (Trên máy tính chạy Game)
Đây là máy đang chạy Server Minecraft (Home PC, máy ảo, v.v.).

1.  Mở script và chọn **Option 2** (`Cài đặt FRP CLIENT`).
2.  **IP VPS**: Nhập IP của máy VPS ở Bước 1.
3.  **Control Port & Token**: Nhập y hệt thông tin đã cài trên VPS.
4.  **Dummy IP**: Nhập IP ảo (ví dụ: `192.168.254.1`). Đây là IP bạn sẽ dùng để bind trong config Minecraft.
5.  **Cấu hình Port**:
    -   Nhập dải port (Ví dụ: `25565-25565`).
    -   Chọn có bật **Proxy Protocol** hay không (Chỉ bật nếu dùng BungeeCord/Velocity).
6.  **Hoàn tất**: Script tạo IP ảo, kết nối tunnel và tạo service khởi động cùng máy.

---

## ⚡ Mô phỏng kịch bản sử dụng (Simulations)

### Kịch bản A: Server Paper/Spigot (Java Edition)
*   **Mục tiêu**: Mở port 25565.
*   **Thực hiện**:
    1.  Cài Client trên máy chạy Paper.
    2.  Dummy IP: `192.168.254.1`.
    3.  Port range: `25565-25565`.
    4.  Proxy Protocol: `N` (Tắt).
    5.  Trong `server.properties`, chỉnh: `server-ip=192.168.254.1` và `server-port=25565`.
    6.  Người chơi vào qua: `IP_VPS:25565`.

### Kịch bản B: Cụm BungeeCord + Bedrock (Geyser)
*   **Mục tiêu**: Bungee chạy port 25577 (muốn thấy IP thật), Geyser chạy port 19132.
*   **Thực hiện**:
    1.  **Dải 1**: `25577-25577`, Proxy Protocol: `Y` (Bật).
    2.  **Dải 2**: `19132-19132`, Proxy Protocol: `N` (Tắt).
    3.  Chỉnh `proxy_protocol: true` trong config BungeeCord.
    4.  Người chơi Java vào qua `IP_VPS:25577`, Bedrock vào qua `IP_VPS:19132`.

---

## 🧹 Quản lý & Gỡ cài đặt

-   **Xem trạng thái**: `systemctl status frpc-192-168-254-1` (tùy theo Dummy IP).
-   **Reload cấu hình**: Khi muốn thêm port mà không kick player, chạy lại script chọn Option 2 -> Nhập Dummy IP cũ -> Chọn **Option 1 (Append)**.
-   **Gỡ cài đặt**: Chọn **Option 4** trong menu để xóa sạch service và binary.

---

## ⚠️ Lưu ý quan trọng
-   Nếu dùng **Proxy Protocol**, bạn **bắt buộc** phải cấu hình trong Server Minecraft/Proxy, nếu không người chơi sẽ không thể kết nối.
-   Đảm bảo VPS đã mở các port Game trên Firewall hệ thống (Script đã hỗ trợ mở tự động nhưng hãy kiểm tra lại trên Dashboard của nhà cung cấp VPS - AWS, Azure, Google Cloud, v.v.).

---
*Phát triển bởi anlongawf - V13.0*
