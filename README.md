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

## 🖥️ Mô phỏng cài đặt thực tế (Step-by-Step)

### 1. Cài đặt trên VPS (Server)
Đây là ví dụ khi bạn chạy script trên VPS và chọn Option 1:

```text
=======================================
   AUTO SETUP MINECRAFT FRP TUNNEL     
   V13.0                               
=======================================
1. Cài đặt FRP SERVER
2. Cài đặt FRP CLIENT
4. GỠ CÀI ĐẶT
0. Thoát

Lựa chọn: 1

--- Chọn IP để bind FRP Server ---
  1. 103.178.235.70
Chọn IP [0=Tự gõ]: 1
Control Port [7000]: 7000
Auth Token: ******** (Nhập mật khẩu của bạn)

>> Đang cài đặt binary FRP mới nhất...
>> Đã mở firewall cho Control Port 7000...
>> SERVER ĐÃ CHẠY!
   Service : frps-103-178-235-70
   Config  : /etc/frp/frps-103-178-235-70.toml
```

### 2. Cài đặt trên máy nội bộ (Client)
Đây là ví dụ mô phỏng kịch bản A (Mở port 25565 cho Paper/Spigot):

```text
Lựa chọn: 2
IP VPS (FRP Server): 103.178.235.70
Control Port: 7000
Auth Token: ******** (Nhập mật khẩu y hệt như trên VPS)
IP local của Node này (Dummy IP) [192.168.254.1]: 192.168.254.1

--- Cấu hình Dải Port ---
Thêm dải port mới? (y/N): y
  Port bắt đầu: 25565
  Port kết thúc: 25565
  Bật Proxy Protocol cho dải 25565-25565? (y/N): n
>> Đã thêm 25565-25565 [TCP+UDP, Proxy Protocol: TẮT]

Thêm dải port mới? (y/N): n

>> Dummy IP 192.168.254.1 đã được thêm vào loopback.
>> CLIENT ĐÃ CHẠY!
   Service        : frpc-192-168-254-1
   Dummy IP       : 192.168.254.1
   VPS Server     : 103.178.235.70:7000
   Config         : /etc/frp/frpc-192-168-254-1.toml
```

---

## ⚡ Kịch bản sử dụng (Use Cases)

- **Kịch bản A: Server Paper/Spigot (Java Edition)**
  - Dummy IP: `192.168.254.1`
  - Port: `25565`
  - Proxy Protocol: `N`
  - *Cấu hình trong `server.properties`:*
    ```properties
    server-ip=192.168.254.1
    server-port=25565
    ```
  - *Kết nối:* Người chơi vào bằng `103.178.235.70:25565`.

- **Kịch bản B: Cụm Proxy (Bungee/Velocity) + Bedrock**
  - **Dải 1**: `25577` (Proxy), Proxy Protocol: `Y`.
  - **Dải 2**: `19132` (Bedrock), Proxy Protocol: `N`.
  - *Kết nối:* Java dùng port `25577`, Bedrock dùng port `19132`.

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
