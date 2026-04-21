#!/bin/bash

# ==========================================
# Minecraft + FRP Auto Setup Script (Ubuntu 22.04+)
# Hỗ trợ phân nhánh Server(VPS) và Client(Pterodactyl Node)
# ==========================================

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
echo -e "  ${YELLOW}2.${NC} Cài đặt FRP Client (Trên Node nội bộ chạy Pterodactyl)"
echo -e "  ${YELLOW}4.${NC} Gỡ cài đặt hoàn toàn FRP & Clean hệ thống"
echo -e "  ${YELLOW}0.${NC} Thoát"
read -p "Lựa chọn của bạn [0-4]: " choice

if [[ ! "$choice" =~ ^[1-4]$ ]]; then
    echo "Thoát chương trình."
    exit 0
fi

# ---------------------------------------------
# Function: Cài đặt binary FRP
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

    echo -e "${YELLOW}>> Giải nén và cài đặt binary...${NC}"
    cd /tmp
    tar -xzf frp.tar.gz
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"

    mkdir -p /etc/frp

    # Dừng tất cả frps/frpc service trước khi ghi đè binary tránh lỗi "Text file busy"
    systemctl stop $(systemctl list-units --type=service --state=running --no-legend | grep -oE 'frp[sc]-[^ ]+') 2>/dev/null || true

    cp "$FRP_DIR/frps" /usr/local/bin/
    cp "$FRP_DIR/frpc" /usr/local/bin/
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc

    rm -rf "/tmp/frp.tar.gz" "/tmp/$FRP_DIR"
    echo -e "${GREEN}>> Cài đặt binary FRP thành công.${NC}"
}

# ---------------------------------------------
# Function: Tạo Dummy IP service
# ---------------------------------------------
setup_dummy_ip() {
    if [ "$DUMMY_IP" == "127.0.0.1" ]; then
        echo -e "${GREEN}>> Sử dụng local loopback (127.0.0.1), bỏ qua bước tạo IP ảo.${NC}"
        return 0
    fi
    SERVICE_NAME="pterodactyl-dummy-ip-${DUMMY_IP//./-}"
    echo -e "${YELLOW}>> Đang ghim IP ảo ${DUMMY_IP} vào loopback...${NC}"
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Khoi tao IP cuc bo ${DUMMY_IP} cho Pterodactyl Wings
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
    systemctl enable --now "${SERVICE_NAME}"
    echo -e "${GREEN}>> Đã tạo IP ảo ${DUMMY_IP} thành công.${NC}"
}

# ---------------------------------------------
# Function: Tạo và restart frpc service
# ---------------------------------------------
setup_frpc_service() {
    SERVICE_NAME="frpc-${DUMMY_IP//./-}"

    if [ "$DUMMY_IP" == "127.0.0.1" ]; then
        AFTER_DEP="network.target network-online.target syslog.target"
        WANTS_DEP="network-online.target"
    else
        AFTER_DEP="network.target network-online.target syslog.target pterodactyl-dummy-ip-${DUMMY_IP//./-}.service"
        WANTS_DEP="network-online.target pterodactyl-dummy-ip-${DUMMY_IP//./-}.service"
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=FRP Client ${SERVICE_NAME}
After=${AFTER_DEP}
Wants=${WANTS_DEP}

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc-${DUMMY_IP}.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
}

# ---------------------------------------------
# Function: Mở firewall (tcp + udp)
# ---------------------------------------------
open_firewall_ports() {
    local port_start=$1
    local port_end=$2

    if command -v ufw >/dev/null 2>&1; then
        if [ "$port_start" -eq "$port_end" ]; then
            ufw allow ${port_start}/tcp >/dev/null
            ufw allow ${port_start}/udp >/dev/null
        else
            ufw allow ${port_start}:${port_end}/tcp >/dev/null
            ufw allow ${port_start}:${port_end}/udp >/dev/null
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if [ "$port_start" -eq "$port_end" ]; then
            firewall-cmd --permanent --add-port=${port_start}/tcp >/dev/null
            firewall-cmd --permanent --add-port=${port_start}/udp >/dev/null
        else
            firewall-cmd --permanent --add-port=${port_start}-${port_end}/tcp >/dev/null
            firewall-cmd --permanent --add-port=${port_start}-${port_end}/udp >/dev/null
        fi
    fi
}

apply_firewall() {
    echo -e "${YELLOW}>> Cấu hình Tường Lửa...${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 22/tcp comment "SSH" >/dev/null
        ufw allow ${ctrl_port}/tcp comment "FRP Control" >/dev/null
        open_firewall_ports 25565 25568
        open_firewall_ports 19132 19132
        if [[ "$add_range" =~ ^[Yy]$ ]]; then
            open_firewall_ports $custom_start $custom_end
        fi
        ufw reload >/dev/null
        echo -e "${GREEN}>> Đã mở port UFW.${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=22/tcp >/dev/null
        firewall-cmd --permanent --add-port=${ctrl_port}/tcp >/dev/null
        open_firewall_ports 25565 25568
        open_firewall_ports 19132 19132
        if [[ "$add_range" =~ ^[Yy]$ ]]; then
            open_firewall_ports $custom_start $custom_end
        fi
        firewall-cmd --reload >/dev/null
        echo -e "${GREEN}>> Đã mở port Firewalld.${NC}"
    else
        echo -e "${YELLOW}[Cảnh báo] Không tìm thấy firewall. Vui lòng tự mở port trên panel VPS.${NC}"
    fi
}

# ---------------------------------------------
# Function: Ghi proxies TCP+UDP vào frpc.toml
# ---------------------------------------------
append_proxies_server() {
    local port_start=$1
    local port_end=$2
    local target_file=$3
    # Note: Server config for 0.52+ might not need proxy definitions, 
    # but some users prefer to restrict ports via allowPorts.
    # Currently we open firewall instead.
    return 0
}


# ---------------------------------------------
# Function: Nhập thông tin kết nối Client
# ---------------------------------------------
get_client_common_info() {
    while true; do
        read -p "Nhập Public IP của VPS chạy Server: " vps_ip
        if [[ $vps_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
        echo -e "${RED}Định dạng IPv4 không hợp lệ, vui lòng nhập lại.${NC}"
    done

    read -p "Cổng điều khiển FRP [Mặc định: 7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}

    while true; do
        read -p "Nhập Auth Token: " auth_token
        if [ -n "$auth_token" ]; then break; fi
        echo -e "${RED}Token không được để trống!${NC}"
    done

    echo -e "\n${YELLOW}--- Khởi tạo IP Ảo (Dummy IP) cho Node ---${NC}"
    while true; do
        read -p "Nhập full IP ảo muốn dùng (Ví dụ 192.168.1.10) [Mặc định: 192.168.254.1]: " DUMMY_IP
        DUMMY_IP=${DUMMY_IP:-192.168.254.1}
        if [[ $DUMMY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
        echo -e "${RED}Định dạng IP không hợp lệ!${NC}"
    done
}

# ==============================================
# MODULE 1: SERVER (VPS)
# ==============================================
if [ "$choice" == "1" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP SERVER ===${NC}"

    # --- Bind IP ---
    echo -e "\n${CYAN}--- Chọn IP để bind FRP Server ---${NC}"
    echo -e "${YELLOW}Danh sách IP tĩnh trên máy:${NC}"
    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ ${#IP_LIST[@]} -eq 0 ]; then
        echo -e "${RED}[Cảnh báo] Không detect được IP tĩnh nào.${NC}"
    else
        for i in "${!IP_LIST[@]}"; do
            ip_entry="${IP_LIST[$i]}"
            ip_hint=""
            if [ -f /etc/frp/frps.toml ] && grep -q "${ip_entry}" /etc/frp/frps.toml; then
                ip_hint=" ${CYAN}[frps.toml]${NC}"
            fi
            if [ -f /etc/frp/frpc.toml ] && grep -q "${ip_entry}" /etc/frp/frpc.toml; then
                proxy_names=$(grep -B5 "localIP = \"${ip_entry}\"" /etc/frp/frpc.toml \
                    | grep 'name = ' \
                    | sed -E 's/.*name = "(.*)"/\1/' \
                    | tr '\n' ',' | sed 's/,$//')
                if [ -n "$proxy_names" ]; then
                    ip_hint="${ip_hint} ${CYAN}[frpc.toml: ${proxy_names}]${NC}"
                else
                    ip_hint="${ip_hint} ${CYAN}[frpc.toml]${NC}"
                fi
            fi
            echo -e "  ${YELLOW}$((i+1)).${NC} ${ip_entry}${ip_hint}"
        done
    fi
    echo -e "  ${YELLOW}0.${NC} Tự gõ tay IP khác"
    read -p "Chọn IP [0-${#IP_LIST[@]}]: " ip_choice

    if [[ "$ip_choice" == "0" ]] || [[ -z "$ip_choice" ]] || [[ ! "$ip_choice" =~ ^[0-9]+$ ]] || [ "$ip_choice" -gt "${#IP_LIST[@]}" ]; then
        while true; do
            read -p "Nhập IP muốn bind (bỏ trống = bind tất cả IP): " bind_ip
            if [[ -z "$bind_ip" ]] || [[ $bind_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
            echo -e "${RED}Định dạng IP không hợp lệ!${NC}"
        done
    else
        bind_ip="${IP_LIST[$((ip_choice-1))]}"
    fi

    # --- Control Port & Token ---
    read -p "Cổng điều khiển FRP Control Port [Mặc định: 7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}

    while true; do
        read -p "Nhập Auth Token bảo mật kết nối: " auth_token
        if [ -n "$auth_token" ]; then break; fi
        echo -e "${RED}Token không được để trống!${NC}"
    done

    # --- Custom range port ---
    echo -e "\n${CYAN}--- Cấu hình Port ---${NC}"
    echo -e "Mặc định sẽ mở: ${YELLOW}25565-25568 (TCP+UDP)${NC} và ${YELLOW}19132 (TCP+UDP)${NC}"
    read -p "Thêm custom range port? (y/N): " add_range
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "Port bắt đầu: " custom_start
            read -p "Port kết thúc: " custom_end
            if [[ "$custom_start" =~ ^[0-9]+$ ]] && [[ "$custom_end" =~ ^[0-9]+$ ]] && [ "$custom_end" -ge "$custom_start" ]; then
                break
            fi
            echo -e "${RED}Range không hợp lệ!${NC}"
        done
    fi

    # --- Tóm tắt ---
    echo -e "\n${YELLOW}Tóm tắt cấu hình Server:${NC}"
    echo " - Bind IP      : ${bind_ip:-"0.0.0.0 (tất cả IP)"}"
    echo " - Control Port : $ctrl_port"
    echo " - Auth Token   : $auth_token"
    echo " - Minecraft    : 25565-25568 + 19132 (TCP+UDP)"
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        echo " - Custom Range : $custom_start - $custom_end (TCP+UDP)"
    fi

    read -p "Bạn có chắc chắn muốn cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi

    install_frp_core

    # --- Ghi frps config ---
    FRPS_CONFIG="/etc/frp/frps-${bind_ip:-main}.toml"
    if [ -n "$bind_ip" ]; then
        cat > "${FRPS_CONFIG}" <<EOF
bindAddr = "${bind_ip}"
bindPort = ${ctrl_port}
auth.token = "${auth_token}"
EOF
    else
        cat > "${FRPS_CONFIG}" <<EOF
bindPort = ${ctrl_port}
auth.token = "${auth_token}"
EOF
    fi

    apply_firewall

    # --- frps service (đặt tên theo bind IP để tránh trùng) ---
    FRPS_SERVICE_NAME="frps-${bind_ip:-main}"

    cat > /etc/systemd/system/${FRPS_SERVICE_NAME}.service <<EOF
[Unit]
Description=FRP Server ${FRPS_SERVICE_NAME}
After=network.target network-online.target syslog.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c ${FRPS_CONFIG}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${FRPS_SERVICE_NAME}"
    systemctl restart "${FRPS_SERVICE_NAME}"

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất cài đặt FRP Server!${NC}"
    systemctl status "${FRPS_SERVICE_NAME}" --no-pager | grep Active
    echo -e "${YELLOW}>> Service   : ${FRPS_SERVICE_NAME}.service${NC}"
    echo -e "${YELLOW}>> Bind IP   : ${bind_ip:-"0.0.0.0 (tất cả IP)"}${NC}"
    echo -e "${YELLOW}>> Minecraft : 25565-25568 + 19132 (TCP+UDP)${NC}"
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}>> Custom    : ${custom_start}-${custom_end} (TCP+UDP)${NC}"
    fi
    echo -e "${GREEN}==========================================${NC}"
fi

# ==============================================
# MODULE 2: CLIENT (NODE PTERODACTYL)
# ==============================================
if [ "$choice" == "2" ]; then
    echo -e "\n${GREEN}=== THIẾT LẬP FRP CLIENT (PTERODACTYL NODE) ===${NC}"

    get_client_common_info

    # --- Custom range port ---
    echo -e "\n${CYAN}--- Cấu hình Port ---${NC}"
    echo -e "Mặc định sẽ tunnel: ${YELLOW}25565-25568 (TCP+UDP)${NC} và ${YELLOW}19132 (TCP+UDP)${NC}"
    read -p "Thêm custom range port? (y/N): " add_range
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "Port bắt đầu: " custom_start
            read -p "Port kết thúc: " custom_end
            if [[ "$custom_start" =~ ^[0-9]+$ ]] && [[ "$custom_end" =~ ^[0-9]+$ ]] && [ "$custom_end" -ge "$custom_start" ]; then
                break
            fi
            echo -e "${RED}Range không hợp lệ!${NC}"
        done
    fi

    # --- Tóm tắt ---
    echo -e "\n${YELLOW}Tóm tắt cấu hình Client:${NC}"
    echo " - Kết nối Server : $vps_ip:$ctrl_port"
    echo " - Dummy IP       : ${DUMMY_IP}"
    echo " - Minecraft      : 25565-25568 + 19132 (TCP+UDP)"
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        echo " - Custom Range   : $custom_start - $custom_end (TCP+UDP)"
    fi

    read -p "Tiếp tục cài đặt? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then exit 0; fi

    setup_dummy_ip
    install_frp_core

    # --- Ghi frpc-{DUMMY_IP}.toml (riêng cho từng node theo IP) ---
    FRPC_CONFIG="/etc/frp/frpc-${DUMMY_IP}.toml"
    echo -e "${YELLOW}>> Tạo file cấu hình ${FRPC_CONFIG}...${NC}"
    cat > "${FRPC_CONFIG}" <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}
auth.token = "${auth_token}"

EOF

    # Minecraft mặc định: 25565-25568 + 19132 (TCP+UDP)
    append_proxies "mc" 25565 25568 "${DUMMY_IP}" "${FRPC_CONFIG}"
    append_proxies "mc" 19132 19132 "${DUMMY_IP}" "${FRPC_CONFIG}"

    # Custom range nếu có
    if [[ "$add_range" =~ ^[Yy]$ ]]; then
        append_proxies "mc" $custom_start $custom_end "${DUMMY_IP}" "${FRPC_CONFIG}"
    fi

    setup_frpc_service

    FRPC_SERVICE_NAME="frpc-${DUMMY_IP//./-}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Hoàn tất! FRP Client đang chạy:${NC}"
    systemctl status "${FRPC_SERVICE_NAME}" --no-pager | grep Active
    echo -e "${YELLOW}>> Service   : ${FRPC_SERVICE_NAME}.service${NC}"
    echo -e "${YELLOW}>> Config    : ${FRPC_CONFIG}${NC}"
    echo -e "${YELLOW}>> Pterodactyl Node:${NC}"
    echo -e "${YELLOW}   IP Address = ${DUMMY_IP}${NC}"
    echo -e "${YELLOW}   IP Alias   = ${vps_ip}${NC}"
    echo -e "${GREEN}==========================================${NC}"
fi

# ==============================================
# MODULE 4: UNINSTALL
# ==============================================
if [ "$choice" == "4" ]; then
    echo -e "\n${RED}=== TIẾN HÀNH GỠ CÀI ĐẶT HOÀN TOÀN FRP ===${NC}"
    read -p "Bạn có chắc chắn muốn xoá sạch mọi cấu hình FRP? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi

    echo -e "${YELLOW}>> Đang dừng và gỡ bỏ tất cả các service liên quan...${NC}"
    
    # Tìm và list các service frps-*, frpc-*, pterodactyl-dummy-ip-*
    SERVICES=$(systemctl list-unit-files | grep -E 'frps-|frpc-|pterodactyl-dummy-ip-' | awk '{print $1}')
    # Thêm cả các service cũ nếu có
    SERVICES="${SERVICES} frps.service frpc.service pterodactyl-dummy-ip.service"

    for svc in ${SERVICES}; do
        if [ -f "/etc/systemd/system/${svc}" ]; then
            echo "  - Đang dừng ${svc}..."
            systemctl stop "${svc}" 2>/dev/null
            systemctl disable "${svc}" 2>/dev/null
            rm -f "/etc/systemd/system/${svc}"
            echo "  - Đã xoá ${svc}"
        fi
    done

    systemctl daemon-reload
    systemctl reset-failed

    echo -e "${YELLOW}>> Đang gỡ bỏ cấu hình và binary...${NC}"
    rm -rf /etc/frp
    # Chỉ xoá binary nếu không dùng cho việc khác
    read -p "Có xoá luôn file chạy /usr/local/bin/frp* không? (y/N): " del_bin
    if [[ "$del_bin" =~ ^[Yy]$ ]]; then
        rm -f /usr/local/bin/frps /usr/local/bin/frpc
    fi
    
    echo -e "${YELLOW}>> Đang dọn dẹp các IP ảo trên loopback...${NC}"
    # Xoá tất cả IP ảo mà script này từng tạo (IP/32 ngoại trừ 127.0.0.1)
    ip addr show dev lo | grep "/32" | grep -v "127.0.0.1" | awk '{print $2}' | while read -r ip_cidr; do
        echo "  - Đang gỡ IP: ${ip_cidr}"
        ip addr del "${ip_cidr}" dev lo 2>/dev/null
    done

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}ĐÃ GỠ CÀI ĐẶT HOÀN TOÀN! Hệ thống đã sạch sẽ.${NC}"
    echo -e "${GREEN}==========================================${NC}"
fi