#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL (Ultimate Edition)
# ======================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Lỗi] Vui lòng chạy script với quyền root.${NC}"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then FRP_ARCH="amd64"; elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then FRP_ARCH="arm64"; else echo -e "${RED}CPU không hỗ trợ${NC}"; exit 1; fi

# Luôn đảm bảo thư mục cấu hình tồn tại
mkdir -p /etc/frp

# ---------------------------------------------
# Function: Cài đặt binary FRP
# ---------------------------------------------
install_frp_core() {
    if [ -f "/usr/local/bin/frps" ] && [ -f "/usr/local/bin/frpc" ]; then
        echo -e "${GREEN}>> Lõi FRP đã có sẵn, bỏ qua bước cài đặt binary.${NC}"
        return 0
    fi
    echo -e "${YELLOW}>> Đang cài đặt binary FRP mới nhất...${NC}"
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    VERSION_NUM=${LATEST_RELEASE#v}
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_RELEASE}/frp_${VERSION_NUM}_linux_${FRP_ARCH}.tar.gz"
    wget -q --show-progress "$DOWNLOAD_URL" -O "/tmp/frp.tar.gz"
    cd /tmp && tar -xzf frp.tar.gz
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"
    mkdir -p /etc/frp
    cp "$FRP_DIR/frps" /usr/local/bin/frps
    cp "$FRP_DIR/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frp*
    echo -e "${GREEN}>> Cài đặt binary FRP thành công.${NC}"
}

# ---------------------------------------------
# Function: Nhập nhiều dải port custom
# ---------------------------------------------
CUSTOM_RANGES=""
get_custom_ranges() {
    echo -e "\n${CYAN}--- Cấu hình Port Custom ---${NC}"
    while true; do
        read -p "Thêm dải port mới? (y/N): " add_more
        if [[ ! "$add_more" =~ ^[Yy]$ ]]; then break; fi
        read -p "  Port bắt đầu: " p_s
        read -p "  Port kết thúc: " p_e
        if [[ "$p_s" =~ ^[0-9]+$ ]] && [ "$p_s" -le 65535 ] && [ "$p_e" -le 65535 ] && [ "$p_e" -ge "$p_s" ]; then
            CUSTOM_RANGES="${CUSTOM_RANGES}${p_s}-${p_e} "
        else
            echo -e "${RED}  >> Lỗi: Port không hợp lệ!${NC}"
        fi
    done
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
transport.proxyProtocolVersion = "v2"

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
# MENU
# ==============================================
clear
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   AUTO SETUP MINECRAFT FRP TUNNEL   ${NC}"
echo -e "${GREEN}=====================================${NC}"
echo "1. Cài đặt FRP SERVER"
echo "2. Cài đặt FRP CLIENT"
echo "4. GỠ CÀI ĐẶT (Hỗ trợ xoá từng cái)"
echo "0. Thoát"
read -p "Lựa chọn: " choice

# --- SERVER ---
if [ "$choice" == "1" ]; then
    echo -e "\n${CYAN}--- Chọn IP để bind FRP Server ---${NC}"
    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    for i in "${!IP_LIST[@]}"; do
        curr_ip="${IP_LIST[$i]}"
        hint=""
        # Quét thông minh: Hiện luôn tên file đang dùng IP này
        if ls /etc/frp/*.toml >/dev/null 2>&1; then
            file_using=$(grep -rlE "bindAddr = \"$curr_ip\"|localIP = \"$curr_ip\"" /etc/frp/*.toml | xargs -n1 basename 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            if [ -n "$file_using" ]; then
                hint="${CYAN}[File: $file_using]${NC}"
            fi
        fi
        echo -e "  ${YELLOW}$((i+1)).${NC} ${curr_ip} ${hint}"
    done
    read -p "Chọn IP [0=Tự gõ]: " ip_idx
    if [ "$ip_idx" == "0" ]; then read -p "IP: " bind_ip; else bind_ip="${IP_LIST[$((ip_idx-1))]}"; fi
    
    read -p "Control Port [7000]: " ctrl_port; ctrl_port=${ctrl_port:-7000}
    read -p "Auth Token: " auth_token
    get_custom_ranges
    
    install_frp_core
    CONF="/etc/frp/frps-${bind_ip:-all}.toml"
    cat > "$CONF" <<EOF
bindAddr = "${bind_ip:-0.0.0.0}"
bindPort = ${ctrl_port}
auth.token = "${auth_token}"
EOF
    SVC="frps-${bind_ip:-all}"
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Server ${SVC}
After=network.target
[Service]
ExecStart=/usr/local/bin/frps -c $CONF
Restart=always
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
    # Setup Dummy IP
    if [ "$DUMMY_IP" != "127.0.0.1" ] && ! ip addr show | grep -q "inet ${DUMMY_IP}/"; then
        D_SVC="pterodactyl-dummy-ip-${DUMMY_IP//./-}"
        cat > /etc/systemd/system/${D_SVC}.service <<EOF
[Unit]
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip addr add ${DUMMY_IP}/32 dev lo
ExecStop=/sbin/ip addr del ${DUMMY_IP}/32 dev lo
[Install]
WantedBy=sysinit.target
EOF
        systemctl daemon-reload && systemctl enable --now "$D_SVC"
    fi

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
After=network.target
[Service]
ExecStart=/usr/local/bin/frpc -c $CONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now "$SVC"
    echo -e "${GREEN}>> CLIENT ${SVC} ĐÃ CHẠY!${NC}"
fi

# --- UNINSTALL ---
if [ "$choice" == "4" ]; then
    echo -e "\n${RED}=== CHẾ ĐỘ GỠ CÀI ĐẶT ===${NC}"
    echo "1. Xoá một cụm cụ thể"
    echo "2. Xoá SẠCH TOÀN BỘ"
    read -p "Chọn: " un_choice
    if [ "$un_choice" == "1" ]; then
        mapfile -t LIST < <(systemctl list-unit-files | grep -E 'frps-|frpc-' | awk '{print $1}')
        for i in "${!LIST[@]}"; do echo "$((i+1)). ${LIST[$i]}"; done
        read -p "Chọn số: " idx
        target="${LIST[$((idx-1))]}"
        if [ -n "$target" ]; then
            systemctl stop "$target" && systemctl disable "$target"
            rm -f "/etc/systemd/system/$target" "/etc/frp/${target}.toml"
            # Cleanup Dummy IP if Client
            if [[ "$target" == frpc-* ]]; then
                ip_suff="${target#frpc-}"
                d_svc="pterodactyl-dummy-ip-$ip_suff"
                systemctl stop "$d_svc" 2>/dev/null && rm -f "/etc/systemd/system/${d_svc}.service"
                raw_ip="${ip_suff//-/ .}"; raw_ip=$(echo $raw_ip | tr -d ' ')
                ip addr del "${raw_ip}/32" dev lo 2>/dev/null
            fi
            systemctl daemon-reload && echo -e "${GREEN}>> Đã xoá $target${NC}"
        fi
    elif [ "$un_choice" == "2" ]; then
        read -p "XOÁ SẠCH? (y/N): " conf
        if [[ "$conf" =~ ^[Yy]$ ]]; then
            SERVICES=$(systemctl list-unit-files | grep -E 'frps-|frpc-|pterodactyl-dummy-ip-' | awk '{print $1}')
            for s in $SERVICES; do systemctl stop "$s" 2>/dev/null; systemctl disable "$s" 2>/dev/null; rm -f "/etc/systemd/system/$s"; done
            rm -rf /etc/frp
            ip addr show dev lo | grep "/32" | grep -v "127.0.0.1" | awk '{print $2}' | xargs -I{} ip addr del {} dev lo 2>/dev/null
            echo -e "${RED}>> ĐÃ XOÁ SẠCH!${NC}"
        fi
    fi
fi