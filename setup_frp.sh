#!/bin/bash

# ==========================================
# Minecraft + FRP Auto Setup Script (Ubuntu 22.04+)
# Hỗ trợ phân nhánh Server(VPS) và Client(Pterodactyl Node)
# ==========================================

# Colors
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
CYAN='\e[36m'
NC='\e[0m'

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
echo -e "  ${YELLOW}2.${NC} Cài đặt FRP Client - Port đơn lẻ (Trên Node nội bộ chạy Pterodactyl)"
echo -e "  ${YELLOW}3.${NC} Cài đặt FRP Client - Range Port (Thêm nhiều port liên tiếp)"
echo -e "  ${YELLOW}0.${NC} Thoát"
read -p "Lựa chọn của bạn [0-3]: " choice

if [[ ! "$choice" =~ ^[1-3]$ ]]; then
    echo "Thoát chương trình."
    exit 0
fi

# ---------------------------------------------
# Function: Cài đặt Core rỗng của FRP
# ---------------------------------------------
install_frp_core() {
    echo -e "${YELLOW}>> Đang lấy phiên bản FRP mới nhất từ GitHub...${NC}"
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
# Function: Kiểm tra tên proxy có bị trùng không
# ---------------------------------------------
check_proxy_name_exists() {
    local name="$1"
    local config_file="/etc/frp/frpc.toml"
    if [ -f "$config_file" ] && grep -q "name = \"${name}\"" "$config_file"; then
        return 0  # Trùng
    fi
    return 1  # Không trùng
}

# ---------------------------------------------
# Function: Nhập thông tin kết nối Client chung
# ---------------------------------------------
get_client_common_info() {
    while true; do
        read -p "Nhập Public IP của VPS chạy Server: " vps_ip
        if [[ $vps_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
        echo -e "${RED}Vui lòng nhập lại định dạng IPv4 hợp lệ.${NC}"
    done

    read -p "Cổng điều khiển FRP Server VPS đang dùng [Mặc định: 7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}

    while true; do
        read -p "Nhập Auth Token đã lưu ở Server: " auth_token
        if [ -n "$auth_token" ]; then break; fi
        echo -e "${RED}Token không được để trống!${NC}"
    done

    echo -e "\n${YELLOW}--- Khởi tạo IP Ảo (Dummy IP) cho Node ---${NC}"
    echo "Dải phân bổ IP nội bộ gợi ý: 192.168.254.X"
    read -p "Nhập phần SỐ CUỐI (X) cho IP ảo (1-254) [Mặc định: 1]: " ip_octet
    ip_octet=${ip_octet:-1}
    DUMMY_IP="192.168.254.${ip_octet}"
}

# ---------------------------------------------
# Function: Tạo Dummy IP service
# ---------------------------------------------
setup_dummy_ip() {
    echo -e "${YELLOW}>> Đang ghim IP ảo ${DUMMY_IP} vào loopback...${NC}"
    cat > /etc/systemd/system/pterodactyl-dummy-ip.service <<EOF
[Unit]
Description=Khoi tao IP cuc bo cho Pterodactyl Wings phuc vu he thong proxy
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
    echo -e "${GREEN}>> Đã tạo IP ảo thành công.${NC}"
}

# ---------------------------------------------
# Function: Tạo frpc service
# FIX: Dùng `restart` thay vì `enable --now` để đảm bảo
#      frpc luôn nhận config mới dù service đang chạy sẵn.
# ---------------------------------------------
setup_frpc_service() {
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
    systemctl enable frpc
    systemctl restart frpc  # Ép restart để nhận config mới dù service đang chạy sẵn
}

# ---------------------------------------------
# MODULE 1: SERVER (VPS)
# ---------------------------------------------
if [ "$choice" == "1" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP SERVER ===${NC}"

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

    cat > /etc/frp/frps.toml <<EOF
bindPort = $ctrl_port
auth.token = "$auth_token"
EOF

    echo -e "${YELLOW}>> Cấu hình Tường Lửa (Firewall)...${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 22/tcp comment "SSH Failsafe"
        ufw allow $ctrl_port/tcp comment "FRP Control Port"
        ufw allow 25565:25568/tcp comment "Minecraft Java"
        ufw allow 19132/udp comment "Minecraft Bedrock"
        ufw reload
        echo -e "${GREEN}>> Đã mở port UFW.${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=${ctrl_port}/tcp
        firewall-cmd --permanent --add-port=25565-25568/tcp
        firewall-cmd --permanent --add-port=19132/udp
        firewall-cmd --reload
        echo -e "${GREEN}>> Đã mở port Firewalld.${NC}"
    else
        echo -e "${YELLOW}[Cảnh báo] Không tìm thấy firewall. Vui lòng tự mở port trên panel VPS.${NC}"
    fi

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
    echo -e "${GREEN}Hoàn tất cài đặt Server FRP. Trạng thái:${NC}"
    systemctl status frps --no-pager | grep Active
    echo -e "${GREEN}==========================================${NC}"
fi

# ---------------------------------------------
# MODULE 2: CLIENT - PORT ĐƠN LẺ
# ---------------------------------------------
if [ "$choice" == "2" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP CLIENT - PORT ĐƠN LẺ ===${NC}"

    get_client_common_info

    # Đặt tên proxy
    echo -e "\n${CYAN}--- Cấu hình Proxy ---${NC}"
    while true; do
        read -p "Đặt tên cho proxy này (VD: server-survival, hub-node1): " proxy_name
        if [ -z "$proxy_name" ]; then
            echo -e "${RED}Tên không được để trống!${NC}"
            continue
        fi
        if check_proxy_name_exists "$proxy_name"; then
            echo -e "${RED}[Lỗi] Tên proxy '${proxy_name}' đã tồn tại trong config! Vui lòng chọn tên khác.${NC}"
            continue
        fi
        break
    done

    read -p "Nhập port local (port trên Node): " local_port
    read -p "Nhập port remote (port expose ra VPS): " remote_port

    echo -e "\n${YELLOW}Tóm tắt cấu hình Client:${NC}"
    echo " - Kết nối Server : $vps_ip:$ctrl_port"
    echo " - Dummy IP       : ${DUMMY_IP}"
    echo " - Tên Proxy      : ${proxy_name}-tcp / ${proxy_name}-udp"
    echo " - Port Local     : $local_port → Remote: $remote_port"
    echo " - Loại           : TCP + UDP (tạo cả 2)"

    read -p "Tiếp tục cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi

    setup_dummy_ip
    install_frp_core

    echo -e "${YELLOW}>> Tạo file cấu hình frpc...${NC}"

    # Nếu file chưa có thì tạo header, nếu có rồi thì chỉ append proxy
    if [ ! -f /etc/frp/frpc.toml ]; then
        cat > /etc/frp/frpc.toml <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}
auth.token = "${auth_token}"

EOF
    fi

    cat >> /etc/frp/frpc.toml <<EOF
[[proxies]]
name = "${proxy_name}-tcp"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = ${local_port}
remotePort = ${remote_port}

[[proxies]]
name = "${proxy_name}-udp"
type = "udp"
localIP = "${DUMMY_IP}"
localPort = ${local_port}
remotePort = ${remote_port}

EOF

    setup_frpc_service

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất! FRPC đang chạy:${NC}"
    systemctl status frpc --no-pager | grep Active
    echo -e "${YELLOW}>> Pterodactyl Node: IP Address = ${DUMMY_IP} | IP Alias = ${vps_ip}${NC}"
    echo -e "${GREEN}==========================================${NC}"
fi

# ---------------------------------------------
# MODULE 3: CLIENT - RANGE PORT
# ---------------------------------------------
if [ "$choice" == "3" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP CLIENT - RANGE PORT ===${NC}"

    get_client_common_info

    echo -e "\n${CYAN}--- Cấu hình Range Port ---${NC}"

    read -p "Đặt tên prefix cho range này (VD: survival, lobby, minigame): " proxy_prefix
    if [ -z "$proxy_prefix" ]; then
        echo -e "${RED}Tên không được để trống!${NC}"
        exit 1
    fi

    while true; do
        read -p "Port bắt đầu (VD: 25565): " port_start
        read -p "Port kết thúc (VD: 25570): " port_end
        if [[ "$port_start" =~ ^[0-9]+$ ]] && [[ "$port_end" =~ ^[0-9]+$ ]] && [ "$port_end" -ge "$port_start" ]; then
            break
        fi
        echo -e "${RED}Port không hợp lệ! Port kết thúc phải lớn hơn hoặc bằng port bắt đầu.${NC}"
    done

    total_ports=$((port_end - port_start + 1))
    total_proxies=$((total_ports * 2))

    echo -e "\n${YELLOW}Tóm tắt cấu hình Range Port:${NC}"
    echo " - Kết nối Server : $vps_ip:$ctrl_port"
    echo " - Dummy IP       : ${DUMMY_IP}"
    echo " - Prefix Proxy   : ${proxy_prefix}-tcp-[port] / ${proxy_prefix}-udp-[port]"
    echo " - Loại           : TCP + UDP (tạo cả 2)"
    echo " - Range Port     : ${port_start} → ${port_end} (${total_ports} ports × 2 = ${total_proxies} proxies)"
    echo -e " ${RED}⚠ Config cũ (/etc/frp/frpc.toml) sẽ bị XÓA và tạo mới hoàn toàn!${NC}"

    read -p "Tiếp tục cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi

    setup_dummy_ip
    install_frp_core

    echo -e "${YELLOW}>> Tạo mới hoàn toàn file cấu hình frpc với ${total_proxies} proxies...${NC}"

    # Luôn tạo mới config, xóa file cũ nếu có (thiết kế có chủ ý - đã cảnh báo người dùng ở trên)
    cat > /etc/frp/frpc.toml <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}
auth.token = "${auth_token}"

EOF

    for port in $(seq $port_start $port_end); do
        cat >> /etc/frp/frpc.toml <<EOF
[[proxies]]
name = "${proxy_prefix}-tcp-${port}"
type = "tcp"
localIP = "${DUMMY_IP}"
localPort = ${port}
remotePort = ${port}

[[proxies]]
name = "${proxy_prefix}-udp-${port}"
type = "udp"
localIP = "${DUMMY_IP}"
localPort = ${port}
remotePort = ${port}

EOF
    done

    echo -e "${GREEN}>> Đã tạo ${total_proxies} proxies (TCP + UDP) vào config mới.${NC}"

    setup_frpc_service

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất! FRPC đang chạy:${NC}"
    systemctl status frpc --no-pager | grep Active
    echo -e "${YELLOW}>> Pterodactyl Node: IP Address = ${DUMMY_IP} | IP Alias = ${vps_ip}${NC}"
    echo -e "${GREEN}==========================================${NC}"
fi