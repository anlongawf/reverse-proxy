#!/bin/bash

# ==========================================
# Minecraft + FRP Auto Setup Script (Ubuntu 22.04+)
# Hỗ trợ phân nhánh Server(VPS) và Client(Pterodactyl Node)
# ==========================================

# Colors
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m' # No Color

echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   AUTO SETUP MINECRAFT FRP TUNNEL   ${NC}"
echo -e "${GREEN}=====================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Lỗi] Script yêu cầu quyền root. Vui lòng thử lại với 'sudo bash setup_frp.sh'${NC}"
  exit 1
fi

# Detect Architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    FRP_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    FRP_ARCH="arm64"
else
    echo -e "${RED}[Lỗi] Không hỗ trợ kiến trúc CPU: $ARCH${NC}"
    exit 1
fi

echo -e "Vui lòng chọn hệ thống bạn muốn cài đặt:"
echo -e "  ${YELLOW}1.${NC} Cài đặt FRP Server (Trên máy chủ Public VPS)"
echo -e "  ${YELLOW}2.${NC} Cài đặt FRP Client (Trên Node nội bộ chạy Pterodactyl)"
echo -e "  ${YELLOW}0.${NC} Thoát"
read -p "Lựa chọn của bạn [0-2]: " choice

if [[ ! "$choice" =~ ^[1-2]$ ]]; then
    echo "Thoát chương trình."
    exit 0
fi

# ---------------------------------------------
# Function: Cài đặt Core rỗng của FRP
# ---------------------------------------------
install_frp_core() {
    echo -e "${YELLOW}>> Đang lấy phiên bản FRP mới nhất từ GitHub...${NC}"
    # Dùng Github API lấy bản mới nhất, regex bóc tách tag version
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_RELEASE" ]; then
        echo -e "${RED}[Lỗi] Không thể lấy được thông tin phiên bản FRP từ GitHub.${NC}"
        exit 1
    fi
    VERSION_NUM=${LATEST_RELEASE#v}
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_RELEASE}/frp_${VERSION_NUM}_linux_${FRP_ARCH}.tar.gz"
    
    echo -e "${YELLOW}>> Đang tải FRP ${LATEST_RELEASE} (${FRP_ARCH})...${NC}"
    wget -q --show-progress "$DOWNLOAD_URL" -O "/tmp/frp.tar.gz"
    
    echo -e "${YELLOW}>> Giải nén và cấu hình file hệ thống...${NC}"
    cd /tmp
    tar -xzf frp.tar.gz
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"
    
    mkdir -p /etc/frp
    cp "$FRP_DIR/frps" /usr/local/bin/
    cp "$FRP_DIR/frpc" /usr/local/bin/
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc
    
    rm -rf "/tmp/frp.tar.gz" "/tmp/$FRP_DIR"
    echo -e "${GREEN}>> Tải file chạy cốt lõi FRP thành công.${NC}"
}

# ---------------------------------------------
# MODULE 1: SERVER (VPS)
# ---------------------------------------------
if [ "$choice" == "1" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP SERVER ===${NC}"
    
    # Nhập thông tin
    read -p "Cổng điều khiển FRP Control Port [Mặc định: 7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}
    
    while true; do
        read -p "Nhập Auth Token bảo mật kết nối (VD: PteroSecret123): " auth_token
        if [ -n "$auth_token" ]; then break; fi
        echo -e "${RED}Token không được để trống!${NC}"
    done
    
    echo -e "\n${YELLOW}Tóm tắt cấu hình Server:${NC}"
    echo " - Control Port: $ctrl_port"
    echo " - Auth Token : $auth_token"
    echo " - TCP Ports  : 25565 - 25568"
    echo " - UDP Port   : 19132"
    
    read -p "Bạn có chắc chắn muốn cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi
    
    install_frp_core
    
    # Tạo TOML frps
    cat > /etc/frp/frps.toml <<EOF
bindPort = $ctrl_port
auth.token = "$auth_token"
EOF

    # Firewall
    echo -e "${YELLOW}>> Cấu hình Tường Lửa (Firewall)...${NC}"
    if command -v ufw >/dev/null 2>&1; then
        echo "Tự động thiết lập UFW..."
        ufw allow 22/tcp comment "Quyen truy cap SSH an toan (Failsafe)"
        ufw allow $ctrl_port/tcp comment "FRP Control Port"
        ufw allow 25565:25568/tcp comment "Minecraft Java"
        ufw allow 19132/udp comment "Minecraft Bedrock"
        ufw reload
        echo -e "${GREEN}>> Đã hoàn thành luật mở port với UFW.${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "Tự động thiết lập Firewalld..."
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=${ctrl_port}/tcp
        firewall-cmd --permanent --add-port=25565-25568/tcp
        firewall-cmd --permanent --add-port=19132/udp
        firewall-cmd --reload
        echo -e "${GREEN}>> Đã hoàn thành luật mở port Firewalld.${NC}"
    else
        echo -e "${YELLOW}[Cảnh báo] Không tìm thấy firewall phổ thông (ufw/firewalld) chạy mặc định. Vui lòng tự mở các port trên panel web của nhà cung cấp VPS nếu bạn bị chặn kết nối.${NC}"
    fi

    # Systemd frps
    cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=FRP Server System
After=network.target network-online.target syslog.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now frps
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất cài đặt Server FRP. Trạng thái hoạt động:${NC}"
    systemctl status frps --no-pager | grep Active
    echo -e "${GREEN}==========================================${NC}"
fi

# ---------------------------------------------
# MODULE 2: CLIENT (NODE PTERODACTYL)
# ---------------------------------------------
if [ "$choice" == "2" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP CLIENT (PTERODACTYL NODE) ===${NC}"
    
    while true; do
        read -p "Nhập Public IP của VPS chạy Server: " vps_ip
        if [[ $vps_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
        echo -e "${RED}Vui lòng nhập lại định dạng IPv4 hợp lệ.${NC}"
    done
    
    read -p "Cổng điều khiển FRP Server VPS đang dùng [Mặc định: 7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}
    
    while true; do
        read -p "Nhập Auth Token đã lưu ở Server (Dùng chung để thông với nhau): " auth_token
        if [ -n "$auth_token" ]; then break; fi
        echo -e "${RED}Token không được để trống!${NC}"
    done
    
    echo -e "\n${YELLOW}--- Khởi tạo IP Ảo (Dummy IP) cho Node ---${NC}"
    echo "Pterodactyl cần kết nối với FRP thông qua một IP độc lập trong card mạng nội bộ."
    echo "Dải phân bổ IP nội bộ gợi ý cho bạn là: 192.168.254.X"
    read -p "Vui lòng nhập phần SỐ CUỐI (X) bạn muốn cho IP ảo nảy (Từ 1-254) [Mặc định: 1]: " ip_octet
    ip_octet=${ip_octet:-1}
    DUMMY_IP="192.168.254.${ip_octet}"
    
    echo -e "\n${YELLOW}Tóm tắt cấu hình Client Node:${NC}"
    echo " - Kết nối lên Server : $vps_ip:$ctrl_port"
    echo " - Dummy IP sẽ tạo mới: ${DUMMY_IP}"
    echo " - Token mã hóa bảo mật: $auth_token"
    
    read -p "Bạn có muốn tiếp tục áp dụng cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi
    
    # 1. Tạo Dummy IP Interface Persistent bằng daemon hook
    echo -e "${YELLOW}>> Đang ghim cứng cấu hình IP nội bộ ảo ${DUMMY_IP} vào interface loopback (an toàn qua tái khởi động)...${NC}"
    
    cat > /etc/systemd/system/pterodactyl-dummy-ip.service <<EOF
[Unit]
Description=Khơi tao IP cuc bo cho Pterodactyl Wings phuc vu he thong proxy
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip addr add ${DUMMY_IP}/32 dev lo
ExecStop=/sbin/ip addr del ${DUMMY_IP}/32 dev lo

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable --now pterodactyl-dummy-ip.service
    echo -e "${GREEN}>> Đã tạo IP hệ thống xuất sắc.${NC}"
    
    # 2. Cài đặt Cốt lõi phần mềm
    install_frp_core
    
    # 3. Mảng lệnh cho frpc.toml
    echo -e "${YELLOW}>> Đang chuẩn bị các kênh Proxy...${NC}"
    cat > /etc/frp/frpc.toml <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}
auth.token = "${auth_token}"

# --- Phân đoạn TCP Minecraft (Java) ---
[[proxies]]
name = "mc-tcpport-25565"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = 25565
remotePort = 25565

[[proxies]]
name = "mc-tcpport-25566"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = 25566
remotePort = 25566

[[proxies]]
name = "mc-tcpport-25567"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = 25567
remotePort = 25567

[[proxies]]
name = "mc-tcpport-25568"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = 25568
remotePort = 25568

# --- Phân đoạn UDP Minecraft (Bedrock PE) ---
[[proxies]]
name = "mc-udpport-19132"
type = "udp"
localIP = "${DUMMY_IP}"
localPort = 19132
remotePort = 19132
EOF

    # 4. Tạo hook Service Tunnel cho FRP
    cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRP Client Tunnel chuyen phat du lieu Pterodactyl
After=network.target network-online.target syslog.target pterodactyl-dummy-ip.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now frpc
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất móc nối ngầm ngầm qua Client FRP. Service FRPC đang chạy:${NC}"
    systemctl status frpc --no-pager | grep Active
    echo -e "${YELLOW}>> CHÚ Ý: Tại Node Setting của Pterodactyl Panel, bạn nhớ điền IP Address (thật) là ${DUMMY_IP} và IP Alias là VPS Public IP (${vps_ip}) nhé!${NC}"
    echo -e "${GREEN}==========================================${NC}"
fi
