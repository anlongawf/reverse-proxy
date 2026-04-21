#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL — V12.4
# ======================================================
# Fixes: proxy name collision, port conflict, proxy protocol
#        toggle per-range, webServer hot-reload, uninstall bugs,
#        dummy IP cleanup, UDP never gets PP, summary after install
#        firewall auto-open, reload version-aware, append mode
# ======================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Lỗi] Vui lòng chạy script với quyền root.${NC}"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    FRP_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    FRP_ARCH="arm64"
else
    echo -e "${RED}CPU không hỗ trợ: $ARCH${NC}"
    exit 1
fi

mkdir -p /etc/frp

# ==============================================
# Function: Cài đặt binary FRP
# ==============================================
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
    tar -xzf /tmp/frp.tar.gz -C /tmp
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"
    mkdir -p /etc/frp
    cp "/tmp/${FRP_DIR}/frps" /usr/local/bin/frps
    cp "/tmp/${FRP_DIR}/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frp*
    echo -e "${GREEN}>> Cài đặt binary FRP thành công (v${VERSION_NUM}).${NC}"
}

# ==============================================
# Function: Nhập dải port — lưu dạng array
# Format mỗi phần tử: "ps:pe:use_pp"
# ==============================================
# Khai báo global array (PHẢI khai báo trước khi dùng)
CUSTOM_RANGES=()

get_custom_ranges() {
    CUSTOM_RANGES=()
    echo -e "\n${CYAN}${BOLD}--- Cấu hình Dải Port ---${NC}"
    echo -e "  ${YELLOW}Gợi ý phổ biến:${NC}"
    echo -e "  • BungeeCord/Velocity TCP : 19160-19160  ${RED}→ BẬT Proxy Protocol${NC}"
    echo -e "  • Geyser/Bedrock UDP      : 19132-19132  ${GREEN}→ TẮT Proxy Protocol${NC}"
    echo -e "  • Paper standalone TCP    : 25565-25565  ${GREEN}→ TẮT Proxy Protocol${NC}"
    echo ""

    local has_pp="n"

    while true; do
        read -p "Thêm dải port mới? (y/N): " add_more
        if [[ ! "$add_more" =~ ^[Yy]$ ]]; then break; fi

        read -p "  Port bắt đầu: " p_s
        read -p "  Port kết thúc: " p_e

        # Validate port range
        if ! [[ "$p_s" =~ ^[0-9]+$ ]] || ! [[ "$p_e" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}  >> Lỗi: Port phải là số!${NC}"
            continue
        fi
        if [ "$p_s" -gt 65535 ] || [ "$p_e" -gt 65535 ]; then
            echo -e "${RED}  >> Lỗi: Port không được vượt quá 65535!${NC}"
            continue
        fi
        if [ "$p_e" -lt "$p_s" ]; then
            echo -e "${RED}  >> Lỗi: Port kết thúc phải >= Port bắt đầu!${NC}"
            continue
        fi

        # Check overlap với dải đã nhập
        local overlap=0
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ex_s ex_e ex_pp <<< "$r"
            if [ "$p_s" -le "$ex_e" ] && [ "$p_e" -ge "$ex_s" ]; then
                echo -e "${YELLOW}  >> Cảnh báo: Dải ${p_s}-${p_e} bị trùng với dải đã nhập ${ex_s}-${ex_e}!${NC}"
                overlap=1
                break
            fi
        done
        if [ "$overlap" -eq 1 ]; then
            read -p "  Vẫn tiếp tục thêm dải này? (y/N): " force_add
            if [[ ! "$force_add" =~ ^[Yy]$ ]]; then continue; fi
        fi

        # Hỏi Proxy Protocol cho dải này
        echo -e "  ${YELLOW}Proxy Protocol v2 (TCP only):${NC}"
        echo -e "    Bật nếu đây là port BungeeCord/Velocity."
        echo -e "    TẮT cho Geyser/UDP, Paper standalone, v.v."
        read -p "  Bật Proxy Protocol cho dải ${p_s}-${p_e}? (y/N): " use_pp
        use_pp=$(echo "$use_pp" | tr '[:upper:]' '[:lower:]')
        if [ "$use_pp" != "y" ]; then use_pp="n"; fi

        CUSTOM_RANGES+=("${p_s}:${p_e}:${use_pp}")

        if [ "$use_pp" == "y" ]; then
            has_pp="y"
            echo -e "  ${GREEN}>> Đã thêm ${p_s}-${p_e} [TCP+UDP, Proxy Protocol: BẬT cho TCP]${NC}"
        else
            echo -e "  ${GREEN}>> Đã thêm ${p_s}-${p_e} [TCP+UDP, Proxy Protocol: TẮT]${NC}"
        fi
    done

    # Export cờ PP để hiện cảnh báo sau
    HAS_PP="$has_pp"
}

# ==============================================
# Function: Ghi proxy vào file config
# $1=prefix $2=port_start $3=port_end $4=dummy_ip $5=target_file $6=use_pp(y/n)
# NOTE: PP chỉ apply cho TCP, KHÔNG BAO GIỜ apply cho UDP
# ==============================================
append_proxies() {
    local prefix=$1
    local p_s=$2
    local p_e=$3
    local dip=$4
    local target=$5
    local use_pp=$6
    local dip_dash="${dip//./-}"

    for p in $(seq "$p_s" "$p_e"); do
        # --- TCP block ---
        if [ "$use_pp" == "y" ]; then
            cat >> "$target" <<EOF

[[proxies]]
name = "${prefix}-${dip_dash}-tcp-${p}"
type = "tcp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}
transport.proxyProtocolVersion = "v2"
EOF
        else
            cat >> "$target" <<EOF

[[proxies]]
name = "${prefix}-${dip_dash}-tcp-${p}"
type = "tcp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}
EOF
        fi

        # --- UDP block — KHÔNG bao giờ có PP (FRP không hỗ trợ PP trên UDP) ---
        cat >> "$target" <<EOF

[[proxies]]
name = "${prefix}-${dip_dash}-udp-${p}"
type = "udp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}
EOF
    done
}

# ==============================================
# Function: Hiện cảnh báo PP sau khi cài
# ==============================================
show_pp_warning() {
    echo -e ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  PROXY PROTOCOL V2 ĐÃ BẬT CHO MỘT SỐ DẢI PORT TCP     ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Cần cấu hình thêm trên backend:                            ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  BungeeCord/Waterfall — config.yml:                         ║${NC}"
    echo -e "${RED}║    proxy_protocol: true                                      ║${NC}"
    echo -e "${RED}║    ip_forward: true                                          ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Velocity — velocity.toml:                                   ║${NC}"
    echo -e "${RED}║    haproxy-protocol = true                                   ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Cài Floodgate để fix IP Bedrock player.                    ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  ❌ Backend KHÔNG hỗ trợ PP → Player KHÔNG vào được!        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
}
# ==============================================
# Function: Tự động mở port trên firewall
# Hỗ trợ: ufw, firewalld, iptables
# ==============================================
firewall_open_port() {
    local port=$1
    local proto=${2:-tcp}  # mặc định tcp

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
        echo -e "${GREEN}   [UFW] Đã mở ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        echo -e "${GREEN}   [FirewallD] Đã mở ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
        # Tránh duplicate rule
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
            echo -e "${GREEN}   [iptables] Đã mở ${port}/${proto}${NC}"
        fi
    fi
}

# Detect firewall đang chạy
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

# ==============================================
# MENU CHÍNH
# ==============================================
clear
echo -e "${GREEN}${BOLD}=======================================${NC}"
echo -e "${GREEN}${BOLD}   AUTO SETUP MINECRAFT FRP TUNNEL     ${NC}"
echo -e "${GREEN}${BOLD}   V12.4                               ${NC}"
echo -e "${GREEN}${BOLD}=======================================${NC}"
echo "1. Cài đặt FRP SERVER"
echo "2. Cài đặt FRP CLIENT"
echo "4. GỠ CÀI ĐẶT"
echo "0. Thoát"
echo ""
read -p "Lựa chọn: " choice

# ==============================================
# --- 1. SERVER ---
# ==============================================
if [ "$choice" == "1" ]; then
    echo -e "\n${CYAN}--- Chọn IP để bind FRP Server ---${NC}"
    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

    for i in "${!IP_LIST[@]}"; do
        curr_ip="${IP_LIST[$i]}"
        hint=""
        if ls /etc/frp/*.toml >/dev/null 2>&1; then
            file_using=$(grep -rlE "bindAddr = \"$curr_ip\"" /etc/frp/*.toml 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            if [ -n "$file_using" ]; then
                hint="${CYAN}[Đang dùng: $file_using]${NC}"
            fi
        fi
        echo -e "  ${YELLOW}$((i+1)).${NC} ${curr_ip} ${hint}"
    done

    read -p "Chọn IP [0=Tự gõ]: " ip_idx
    if [ "$ip_idx" == "0" ]; then
        read -p "Nhập IP: " bind_ip
    else
        bind_ip="${IP_LIST[$((ip_idx-1))]}"
    fi

    if [ -z "$bind_ip" ]; then
        echo -e "${RED}>> Lỗi: IP không hợp lệ.${NC}"
        exit 1
    fi

    read -p "Control Port [7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}
    read -p "Auth Token: " auth_token

    if [ -z "$auth_token" ]; then
        echo -e "${RED}>> Lỗi: Auth token không được để trống.${NC}"
        exit 1
    fi

    install_frp_core

    # --- Mở firewall cho Control Port ---
    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Đang mở firewall cho Control Port ${ctrl_port}...${NC}"
        firewall_open_port "$ctrl_port" "tcp"
        [ "${FIREWALLD_RELOAD:-0}" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0
    fi

    CONF="/etc/frp/frps-${bind_ip//./-}.toml"
    cat > "$CONF" <<EOF
bindAddr = "${bind_ip}"
bindPort = ${ctrl_port}

[auth]
method = "token"
token = "${auth_token}"
EOF

    SVC="frps-${bind_ip//./-}"
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Server (${bind_ip})
After=network.target

[Service]
ExecStart=/usr/local/bin/frps -c ${CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SVC"

    echo -e ""
    echo -e "${GREEN}${BOLD}>> SERVER ĐÃ CHẠY!${NC}"
    echo -e "${GREEN}   Service : ${SVC}${NC}"
    echo -e "${GREEN}   Bind IP : ${bind_ip}${NC}"
    echo -e "${GREEN}   Port    : ${ctrl_port}${NC}"
    echo -e "${GREEN}   Config  : ${CONF}${NC}"
fi

# ==============================================
# --- 2. CLIENT ---
# ==============================================
if [ "$choice" == "2" ]; then
    read -p "IP VPS (FRP Server): " vps_ip
    read -p "Control Port: " ctrl_port
    read -p "Auth Token: " auth_token
    read -p "IP local của Node này (Dummy IP) [192.168.254.1]: " DUMMY_IP
    DUMMY_IP=${DUMMY_IP:-192.168.254.1}

    if [ -z "$vps_ip" ] || [ -z "$ctrl_port" ] || [ -z "$auth_token" ]; then
        echo -e "${RED}>> Lỗi: VPS IP, Control Port, Auth Token không được để trống.${NC}"
        exit 1
    fi

    # Validate Dummy IP — phải đúng format IPv4 thuần số
    if [[ ! "$DUMMY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}>> Lỗi: Dummy IP '${DUMMY_IP}' không hợp lệ.${NC}"
        echo -e "${RED}   Phải là dạng x.x.x.x (ví dụ: 192.168.1.36)${NC}"
        exit 1
    fi

    SVC="frpc-${DUMMY_IP//./-}"
    CONF="/etc/frp/${SVC}.toml"

    MODE="install"  # mặc định: cài mới

    if [ -f "$CONF" ]; then
        echo -e ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠️  Đã tìm thấy config cho IP ${DUMMY_IP}${NC}"
        echo -e "${YELLOW}║  File: ${CONF}${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1. Thêm port mới vào config hiện tại (giữ nguyên port cũ)"
        echo "  2. Ghi đè toàn bộ (xoá config cũ, nhập lại từ đầu)"
        echo "  0. Huỷ"
        read -p "Chọn: " overwrite_choice

        case "$overwrite_choice" in
            1) MODE="append" ;;
            2) MODE="overwrite" ;;
            *)
                echo -e "${YELLOW}>> Đã huỷ.${NC}"
                exit 0
                ;;
        esac
    fi

    get_custom_ranges

    if [ "${#CUSTOM_RANGES[@]}" -eq 0 ]; then
        echo -e "${RED}>> Lỗi: Chưa nhập dải port nào. Hãy thêm ít nhất 1 dải port.${NC}"
        exit 1
    fi

    install_frp_core

    # --- Setup Dummy IP trên loopback ---
    if ! ip addr show | grep -q "inet ${DUMMY_IP}/"; then
        D_SVC="pterodactyl-dummy-ip-${DUMMY_IP//./-}"
        cat > "/etc/systemd/system/${D_SVC}.service" <<EOF
[Unit]
Description=Dummy IP ${DUMMY_IP} on loopback
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip addr add ${DUMMY_IP}/32 dev lo
ExecStop=/sbin/ip addr del ${DUMMY_IP}/32 dev lo

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$D_SVC"
        echo -e "${GREEN}>> Dummy IP ${DUMMY_IP} đã được thêm vào loopback.${NC}"
    else
        echo -e "${YELLOW}>> Dummy IP ${DUMMY_IP} đã tồn tại, bỏ qua.${NC}"
    fi

    # --- Tính WebServer port: 7400 + octet cuối của Dummy IP ---
    LAST_OCTET="${DUMMY_IP##*.}"
    WS_PORT=$((7400 + LAST_OCTET))

    # Kiểm tra xem WS_PORT đã bị dùng chưa
    if ss -tlnp 2>/dev/null | grep -q ":${WS_PORT} " || grep -r "^port = ${WS_PORT}$" /etc/frp/*.toml 2>/dev/null | grep -v "^$" | grep -q .; then
        echo -e "${YELLOW}>> Cảnh báo: WebServer port ${WS_PORT} có thể đã được dùng bởi instance khác!${NC}"
        echo -e "${YELLOW}   Kiểm tra lại nếu có lỗi reload.${NC}"
    fi

    if [ "$MODE" == "overwrite" ] || [ "$MODE" == "install" ]; then
        # Ghi mới hoàn toàn
        cat > "$CONF" <<EOF
serverAddr = "${vps_ip}"
serverPort = ${ctrl_port}

[auth]
method = "token"
token = "${auth_token}"

[webServer]
addr = "127.0.0.1"
port = ${WS_PORT}
EOF
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe use_pp <<< "$r"
            append_proxies "mc" "$ps" "$pe" "$DUMMY_IP" "$CONF" "$use_pp"
        done

    elif [ "$MODE" == "append" ]; then
        # Chỉ append thêm proxy mới vào cuối file, không đụng header
        echo -e "${CYAN}>> Đang thêm port mới vào config hiện tại...${NC}"

        APPEND_COUNT=0

        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe use_pp <<< "$r"
            for p in $(seq "$ps" "$pe"); do
                # Check xem port này đã có chưa (tcp)
                if grep -q "name = "mc-${DUMMY_IP//./-}-tcp-${p}"" "$CONF"; then
                    echo -e "${YELLOW}   >> Port ${p} đã tồn tại trong config, bỏ qua.${NC}"
                    continue
                fi
                append_proxies "mc" "$p" "$p" "$DUMMY_IP" "$CONF" "$use_pp"
                APPEND_COUNT=$((APPEND_COUNT + 1))
            done
        done

        echo -e "${GREEN}>> Đã thêm ${APPEND_COUNT} port mới vào config.${NC}"

        # Reload thay vì restart để không kick player
        echo -e "${CYAN}>> Đang reload frpc (không kick player)...${NC}"
        FRP_VER_R=$(/usr/local/bin/frpc --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        FRP_MAJ_R=$(echo "$FRP_VER_R" | cut -d. -f1)
        FRP_MIN_R=$(echo "$FRP_VER_R" | cut -d. -f2)
        if [ -n "$FRP_MIN_R" ] && { [ "$FRP_MAJ_R" -ge 1 ] || [ "$FRP_MIN_R" -ge 52 ]; }; then
            if /usr/local/bin/frpc reload -c "$CONF"; then
                echo -e "${GREEN}>> Reload thành công!${NC}"
            else
                echo -e "${YELLOW}>> Reload thất bại, thử restart service...${NC}"
                systemctl restart "$SVC"
            fi
        else
            WS_PORT_R=$(grep "^port = " "$CONF" | head -1 | awk '{print $3}')
            if /usr/local/bin/frpc reload --server_addr 127.0.0.1 --server_port "${WS_PORT_R}"; then
                echo -e "${GREEN}>> Reload thành công!${NC}"
            else
                echo -e "${YELLOW}>> Reload thất bại, thử restart service...${NC}"
                systemctl restart "$SVC"
            fi
        fi
    fi

    # --- Mở firewall cho tất cả dải port đã cấu hình ---
    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Đang mở firewall cho các port đã cấu hình...${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe use_pp_fw <<< "$r"
            for p in $(seq "$ps" "$pe"); do
                firewall_open_port "$p" "tcp"
                firewall_open_port "$p" "udp"
            done
        done
        [ "${FIREWALLD_RELOAD:-0}" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0
        echo -e "${GREEN}>> Firewall đã được cập nhật.${NC}"
    else
        echo -e "${YELLOW}>> Không phát hiện firewall đang hoạt động, bỏ qua bước mở port.${NC}"
    fi

    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Client (${DUMMY_IP})
After=network.target

[Service]
ExecStart=/usr/local/bin/frpc -c ${CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Chỉ start/enable service khi cài mới hoặc ghi đè
    # Append mode đã reload ở trên, không cần restart
    if [ "$MODE" != "append" ]; then
        systemctl daemon-reload
        systemctl enable --now "$SVC"
    fi

    echo -e ""
    echo -e "${GREEN}${BOLD}>> CLIENT ĐÃ CHẠY!${NC}"
    echo -e "${GREEN}   Service        : ${SVC}${NC}"
    echo -e "${GREEN}   Dummy IP       : ${DUMMY_IP}${NC}"
    echo -e "${GREEN}   VPS Server     : ${vps_ip}:${ctrl_port}${NC}"
    echo -e "${GREEN}   Config         : ${CONF}${NC}"
    echo -e "${GREEN}   WebServer port : ${WS_PORT}${NC}"
    echo -e ""
    # Detect FRP version để in đúng lệnh reload
    FRP_VER=$(/usr/local/bin/frpc --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    FRP_MAJOR=$(echo "$FRP_VER" | cut -d. -f1)
    FRP_MINOR=$(echo "$FRP_VER" | cut -d. -f2)

    echo -e "${CYAN}${BOLD}>> Lệnh hot-reload (không kick player):${NC}"
    # v0.52+ hỗ trợ "frpc reload -c <file>" — gọn và chắc chắn hơn
    if [ -n "$FRP_MINOR" ] && [ "$FRP_MAJOR" -ge 1 ] ||        ( [ "$FRP_MAJOR" -eq 0 ] && [ "$FRP_MINOR" -ge 52 ] ); then
        echo -e "${CYAN}   frpc reload -c ${CONF}${NC}"
        echo -e "${YELLOW}   (FRP v${FRP_VER} — dùng syntax mới -c)${NC}"
    else
        echo -e "${CYAN}   frpc reload --server_addr 127.0.0.1 --server_port ${WS_PORT}${NC}"
        echo -e "${YELLOW}   (FRP v${FRP_VER} — dùng syntax cũ; nâng lên v0.52+ để dùng lệnh ngắn hơn)${NC}"
    fi
    echo -e ""
    echo -e "${CYAN}>> Dải port đã cấu hình:${NC}"
    for r in "${CUSTOM_RANGES[@]}"; do
        IFS=':' read -r ps pe use_pp <<< "$r"
        if [ "$use_pp" == "y" ]; then
            echo -e "   ${ps}-${pe}  [PP: ${RED}BẬT${NC}]"
        else
            echo -e "   ${ps}-${pe}  [PP: ${GREEN}TẮT${NC}]"
        fi
    done

    # Hiện cảnh báo nếu có dải bật PP
    if [ "$HAS_PP" == "y" ]; then
        show_pp_warning
    fi
fi

# ==============================================
# --- 4. GỠ CÀI ĐẶT ---
# ==============================================
if [ "$choice" == "4" ]; then
    echo -e "\n${RED}${BOLD}=== CHẾ ĐỘ GỠ CÀI ĐẶT ===${NC}"
    echo "1. Xoá một cụm cụ thể"
    echo "2. Xoá SẠCH TOÀN BỘ"
    read -p "Chọn: " un_choice

    # --- Xoá 1 cụm ---
    if [ "$un_choice" == "1" ]; then
        mapfile -t LIST < <(systemctl list-unit-files | grep -E 'frps-|frpc-' | awk '{print $1}')

        if [ "${#LIST[@]}" -eq 0 ]; then
            echo -e "${YELLOW}>> Không tìm thấy service FRP nào.${NC}"
            exit 0
        fi

        echo -e "\n${CYAN}Danh sách service FRP:${NC}"
        for i in "${!LIST[@]}"; do
            echo "  $((i+1)). ${LIST[$i]}"
        done

        read -p "Chọn số thứ tự: " idx
        target="${LIST[$((idx-1))]}"

        if [ -z "$target" ]; then
            echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"
            exit 1
        fi

        # Strip đuôi .service trước khi xử lý
        target_base="${target%.service}"

        echo -e "${YELLOW}>> Đang xoá: ${target}${NC}"
        systemctl stop "$target" 2>/dev/null
        systemctl disable "$target" 2>/dev/null
        rm -f "/etc/systemd/system/${target}"
        rm -f "/etc/frp/${target_base}.toml"

        # Nếu là client → dọn Dummy IP
        if [[ "$target_base" == frpc-* ]]; then
            ip_suff="${target_base#frpc-}"
            d_svc="pterodactyl-dummy-ip-${ip_suff}"

            systemctl stop "${d_svc}.service" 2>/dev/null
            systemctl disable "${d_svc}.service" 2>/dev/null
            rm -f "/etc/systemd/system/${d_svc}.service"

            # Fix: đổi dấu gạch thành dấu chấm đúng cách
            raw_ip="${ip_suff//-/.}"
            ip addr del "${raw_ip}/32" dev lo 2>/dev/null && \
                echo -e "${GREEN}>> Đã xoá Dummy IP ${raw_ip} khỏi loopback.${NC}"
        fi

        systemctl daemon-reload
        echo -e "${GREEN}>> Đã xoá ${target} thành công.${NC}"

    # --- Xoá sạch toàn bộ ---
    elif [ "$un_choice" == "2" ]; then
        echo -e "${RED}>> CẢNH BÁO: Thao tác này sẽ xoá TOÀN BỘ FRP và Dummy IP!${NC}"
        read -p "Xác nhận XOÁ SẠCH? (y/N): " conf
        if [[ ! "$conf" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}>> Đã huỷ.${NC}"
            exit 0
        fi

        # Thu thập tất cả service
        mapfile -t ALL_SERVICES < <(systemctl list-unit-files | grep -E 'frps-|frpc-|pterodactyl-dummy-ip-' | awk '{print $1}')

        for s in "${ALL_SERVICES[@]}"; do
            s_base="${s%.service}"
            echo -e "${YELLOW}>> Xoá: ${s}${NC}"
            systemctl stop "$s" 2>/dev/null
            systemctl disable "$s" 2>/dev/null
            rm -f "/etc/systemd/system/${s}"
            # Xoá file .toml tương ứng (dùng s_base để tránh "frpc-xxx.service.toml")
            rm -f "/etc/frp/${s_base}.toml"
        done

        # Xoá toàn bộ thư mục config FRP
        rm -rf /etc/frp

        # Dọn tất cả Dummy IP /32 trên loopback (trừ 127.0.0.1)
        ip addr show dev lo | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+(?=/32)' | grep -v '^127\.' | while read -r dip; do
            ip addr del "${dip}/32" dev lo 2>/dev/null && \
                echo -e "${GREEN}>> Đã xoá Dummy IP ${dip} khỏi loopback.${NC}"
        done

        systemctl daemon-reload
        echo -e "${RED}${BOLD}>> ĐÃ XOÁ SẠCH TOÀN BỘ!${NC}"

    else
        echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"
    fi
fi

if [ "$choice" == "0" ]; then
    echo -e "${YELLOW}>> Thoát.${NC}"
    exit 0
fi

if [[ ! "$choice" =~ ^[0124]$ ]]; then
    echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"
    exit 1
fi