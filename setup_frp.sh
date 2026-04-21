#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL (Advanced Multi-Node)
# ======================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Lỗi] Vui lòng chạy script với quyền root (sudo).${NC}"
    exit 1
fi

# Detect kiến trúc CPU
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    FRP_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    FRP_ARCH="arm64"
else
    echo -e "${RED}[Lỗi] Kiến trúc CPU $ARCH không được hỗ trợ.${NC}"
    exit 1
fi

# ---------------------------------------------
# Function: Cài đặt binary FRP
# ---------------------------------------------
install_frp_core() {
    if [ -f "/usr/local/bin/frps" ] && [ -f "/usr/local/bin/frpc" ]; then
        echo -e "${GREEN}>> Lõi FRP đã có sẵn, bỏ qua bước cài đặt binary.${NC}"
        return 0
    fi

    echo -e "${YELLOW}>> Đang lấy phiên bản FRP mới nhất...${NC}"
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    VERSION_NUM=${LATEST_RELEASE#v}
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_RELEASE}/frp_${VERSION_NUM}_linux_${FRP_ARCH}.tar.gz"

    echo -e "${YELLOW}>> Đang tải FRP ${LATEST_RELEASE}...${NC}"
    wget -q --show-progress "$DOWNLOAD_URL" -O "/tmp/frp.tar.gz"
    cd /tmp && tar -xzf frp.tar.gz
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"

    mkdir -p /etc/frp
    cp "$FRP_DIR/frps" /usr/local/bin/frps
    cp "$FRP_DIR/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frp*
    rm -rf "/tmp/frp.tar.gz" "/tmp/$FRP_DIR"
    echo -e "${GREEN}>> Cài đặt binary FRP thành công.${NC}"
}

# ---------------------------------------------
# Function: Nhập nhiều dải port custom
# ---------------------------------------------
CUSTOM_RANGES=""
get_custom_ranges() {
    echo -e "\n${CYAN}--- Cấu hình Port Custom ---${NC}"
    echo -e "Mặc định mở: ${YELLOW}25565-25568${NC} và ${YELLOW}19132${NC}"
    while true; do
        read -p "Thêm dải custom port mới? (y/N): " add_more
        if [[ ! "$add_more" =~ ^[Yy]$ ]]; then break; fi
        
        while true; do
            read -p "  Port bắt đầu: " p_start
            read -p "  Port kết thúc: " p_end
            if [[ "$p_start" =~ ^[0-9]+$ ]] && [[ "$p_end" =~ ^[0-9]+$ ]] && \
               [ "$p_start" -gt 0 ] && [ "$p_start" -le 65535 ] && \
               [ "$p_end" -le 65535 ] && [ "$p_end" -ge "$p_start" ]; then
                CUSTOM_RANGES="${CUSTOM_RANGES}${p_start}-${p_end} "
                echo -e "${GREEN}  >> Đã thêm dải: ${p_start}-${p_end}${NC}"
                break
            fi
            echo -e "${RED}  >> Port hoặc dải không hợp lệ (1-65535)!${NC}"
        done
    done
}

# ---------------------------------------------
# Function: Mở firewall hàng loạt
# ---------------------------------------------
apply_firewall_rules() {
    local ctrl_p=$1
    echo -e "${YELLOW}>> Đang cấu hình Firewall...${NC}"
    if command -v ufw >/dev/null; then
        ufw allow "${ctrl_p}/tcp" >/dev/null
        ufw allow 25565:25568/tcp >/dev/null
        ufw allow 25565:25568/udp >/dev/null
        ufw allow 19132/tcp >/dev/null
        ufw allow 19132/udp >/dev/null
        for range in $CUSTOM_RANGES; do
            p_s=${range%-*}
            p_e=${range#*-}
            if [ "$p_s" -eq "$p_e" ]; then
                ufw allow "${p_s}/tcp" >/dev/null
                ufw allow "${p_s}/udp" >/dev/null
            else
                ufw allow "${p_s}:${p_e}/tcp" >/dev/null
                ufw allow "${p_s}:${p_e}/udp" >/dev/null
            fi
        done
        ufw reload >/dev/null
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port="${ctrl_p}/tcp" >/dev/null
        firewall-cmd --permanent --add-port=25565-25568/tcp >/dev/null
        firewall-cmd --permanent --add-port=25565-25568/udp >/dev/null
        firewall-cmd --permanent --add-port=19132/tcp >/dev/null
        firewall-cmd --permanent --add-port=19132/udp >/dev/null
        for range in $CUSTOM_RANGES; do
            firewall-cmd --permanent --add-port="${range}/tcp" >/dev/null
            firewall-cmd --permanent --add-port="${range}/udp" >/dev/null
        done
        firewall-cmd --reload >/dev/null
    fi
    echo -e "${GREEN}>> Đã mở toàn bộ port trên Firewall.${NC}"
}

# ---------------------------------------------
# Function: IP Ảo (Dummy)
# ---------------------------------------------
setup_dummy_ip() {
    if [ "$DUMMY_IP" == "127.0.0.1" ] || ip addr show | grep -q "inet ${DUMMY_IP}/"; then
        echo -e "${GREEN}>> IP ${DUMMY_IP} đã sẵn sàng.${NC}"
        return 0
    fi
    SERVICE_NAME="pterodactyl-dummy-ip-${DUMMY_IP//./-}"
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=IP Ao ${DUMMY_IP}
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
}

# ---------------------------------------------
# Function: Proxy Client Config
# ---------------------------------------------
append_proxies() {
    local prefix=$1; local p_s=$2; local p_e=$3; local dip=$4; local target=$5
    for p in $(seq $p_s $p_e); do
        cat >> "$target" <<EOF
[[proxies]]
name = "${prefix}-tcp-${p}"
type = "tcp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}

[[proxies]]
name = "${prefix}-udp-${p}"
type = "udp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}
EOF
    done
}

# ==============================================
# MENU CHÍNH
# ==============================================
clear
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   AUTO SETUP MINECRAFT FRP TUNNEL   ${NC}"
echo -e "${GREEN}=====================================${NC}"
echo -e "1. Cài đặt FRP SERVER (Vừa hỗ trợ Multi-IP & Multi-Range)"
echo -e "2. Cài đặt FRP CLIENT (Vừa hỗ trợ Multi-Range)"
echo -e "4. Gỡ cài đặt hoàn toàn"
echo -e "0. Thoát"
read -p "Lựa chọn: " choice

# --- SERVER ---
if [ "$choice" == "1" ]; then
    echo -e "\n${CYAN}--- Chọn IP để bind FRP Server ---${NC}"
    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    for i in "${!IP_LIST[@]}"; do
        curr_ip="${IP_LIST[$i]}"
        hint=""
        # Quét các file config hiện có
        if ls /etc/frp/frps-*.toml >/dev/null 2>&1; then
            for f in /etc/frp/frps-*.toml; do
                if grep -q "bindAddr = \"$curr_ip\"" "$f"; then
                    hint="${CYAN}[Đang dùng cho Server: $(basename "$f" .toml)]${NC}"
                fi
            done
        fi
        echo -e "  ${YELLOW}$((i+1)).${NC} ${curr_ip} ${hint}"
    done
    
    echo -e "  ${YELLOW}0.${NC} Tự gõ tay IP"
    read -p "Chọn IP [0-${#IP_LIST[@]}]: " ip_idx
    if [ "$ip_idx" == "0" ] || [ -z "$ip_idx" ]; then 
        read -p "Nhập IP: " bind_ip
    else 
        bind_ip="${IP_LIST[$((ip_idx-1))]}"
    fi
    
    while true; do
        read -p "Control Port [7000]: " ctrl_port; ctrl_port=${ctrl_port:-7000}
        [ "$ctrl_port" -le 65535 ] && break
        echo -e "${RED}Lỗi: Port tối đa là 65535!${NC}"
    done
    read -p "Auth Token: " auth_token
    get_custom_ranges
    
    install_frp_core
    CONF="/etc/frp/frps-${bind_ip:-all}.toml"
    cat > "$CONF" <<EOF
bindAddr = "${bind_ip:-0.0.0.0}"
bindPort = ${ctrl_port}
auth.token = "${auth_token}"
EOF
    apply_firewall_rules "$ctrl_port"
    SVC="frps-${bind_ip:-all}"
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Server ${SVC}
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c $CONF
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$SVC"
    echo -e "${GREEN}>> SERVER ${SVC} ĐÃ CHẠY!${NC}"
fi

# --- CLIENT ---
if [ "$choice" == "2" ]; then
    read -p "IP VPS: " vps_ip
    read -p "Control Port: " ctrl_port
    read -p "Auth Token: " auth_token
    read -p "IP Ao (Dummy) [192.168.254.1]: " DUMMY_IP; DUMMY_IP=${DUMMY_IP:-192.168.254.1}
    get_custom_ranges
    
    install_frp_core
    setup_dummy_ip
    SVC="frpc-${DUMMY_IP//./-}"
    CONF="/etc/frp/${SVC}.toml"
    cat > "$CONF" <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}
auth.token = "${auth_token}"
EOF
    append_proxies "mc" 25565 25568 "$DUMMY_IP" "$CONF"
    append_proxies "mc" 19132 19132 "$DUMMY_IP" "$CONF"
    for r in $CUSTOM_RANGES; do
        ps=${r%-*}; pe=${r#*-}
        append_proxies "custom" "$ps" "$pe" "$DUMMY_IP" "$CONF"
    done
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Client ${SVC}
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c $CONF
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$SVC"
    echo -e "${GREEN}>> CLIENT ${SVC} ĐÃ CHẠY! Node Pterodactyl dùng IP: ${DUMMY_IP}${NC}"
fi

# --- UNINSTALL ---
if [ "$choice" == "4" ]; then
    SERVICES=$(systemctl list-unit-files | grep -E 'frps-|frpc-|pterodactyl-dummy-ip-' | awk '{print $1}')
    for s in $SERVICES; do systemctl stop "$s" 2>/dev/null; systemctl disable "$s" 2>/dev/null; rm -f "/etc/systemd/system/$s"; done
    systemctl daemon-reload
    rm -rf /etc/frp
    ip addr show dev lo | grep "/32" | grep -v "127.0.0.1" | awk '{print $2}' | xargs -I{} ip addr del {} dev lo 2>/dev/null
    echo -e "${RED}>> ĐÃ XOÁ SẠCH FRP!${NC}"
fi