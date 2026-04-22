#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL — V13.0
# ======================================================
# Changelog từ V12.4:
#   [CRITICAL FIX] grep pattern sai → duplicate proxy không detect được
#   [CRITICAL FIX] version comparison operator precedence bug
#   [SECURITY FIX] auth token ẩn khi nhập (read -s)
#   [MEDIUM FIX]   WS_PORT collision: dùng 3 octet thay vì chỉ octet cuối
#   [MEDIUM FIX]   install_frp_core: kiểm tra binary chạy được, không chỉ tồn tại
#   [MEDIUM FIX]   firewall: cảnh báo rõ khi mở port trên client node
#   [MEDIUM FIX]   uninstall: hỏi xóa binary FRP
#   [MINOR FIX]    loop dùng bash native (( )) thay $(seq ...) — tránh fork subshell
#   [MINOR FIX]    duplicate check áp dụng cả install mode
#   [MINOR FIX]    FIREWALLD_RELOAD khai báo global tường minh
#   [MINOR FIX]    grep -F thay grep -r để tránh regex false-match trên IP
#   [MINOR FIX]    error trap toàn cục
#   [MINOR FIX]    binary không bị xóa ngầm khi uninstall — hỏi user
# ======================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================
# Global error trap — bắt lỗi bất ngờ
# ==============================================
trap 'echo -e "${RED}[Lỗi nghiêm trọng] Script thất bại tại dòng $LINENO. Vui lòng kiểm tra output ở trên.${NC}" >&2' ERR

# ==============================================
# Kiểm tra root
# ==============================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Lỗi] Vui lòng chạy script với quyền root.${NC}"
    exit 1
fi

# ==============================================
# Detect CPU arch
# ==============================================
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

# Khai báo global tường minh — tránh lỗi nếu thêm set -u sau này
FIREWALLD_RELOAD=0
HAS_PP="n"
CUSTOM_RANGES=()

# ==============================================
# Function: So sánh version FRP >= 0.52
# $1=major $2=minor — return 0 nếu đúng, 1 nếu không
# ==============================================
frp_ver_gte_052() {
    local maj="${1:-0}" min="${2:-0}"
    # Validate là số
    if ! [[ "$maj" =~ ^[0-9]+$ ]] || ! [[ "$min" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    (( maj > 0 )) || (( maj == 0 && min >= 52 ))
}

# ==============================================
# Function: Parse version từ binary
# $1=binary path — set FRP_MAJOR và FRP_MINOR
# ==============================================
parse_frp_version() {
    local bin="$1"
    local ver_full
    ver_full=$("$bin" --version 2>/dev/null) || { FRP_MAJOR=0; FRP_MINOR=0; return 1; }
    # Output: "frpc version 0.59.0" hoặc "frpc 0.59.0"
    FRP_MAJOR=$(echo "$ver_full" | grep -oP '\d+(?=\.\d+\.\d+)' | head -1)
    FRP_MINOR=$(echo "$ver_full" | grep -oP '(?<=\.)\d+(?=\.\d+)' | head -1)
    FRP_MAJOR="${FRP_MAJOR:-0}"
    FRP_MINOR="${FRP_MINOR:-0}"
}

# ==============================================
# Function: Cài đặt binary FRP
# Kiểm tra binary CHẠY ĐƯỢC, không chỉ tồn tại
# ==============================================
install_frp_core() {
    if /usr/local/bin/frps --version >/dev/null 2>&1 && \
       /usr/local/bin/frpc --version >/dev/null 2>&1; then
        local ver
        ver=$(/usr/local/bin/frpc --version 2>/dev/null)
        echo -e "${GREEN}>> Lõi FRP đã có sẵn và chạy OK (${ver}), bỏ qua cài đặt binary.${NC}"
        return 0
    fi
    echo -e "${YELLOW}>> Đang cài đặt binary FRP mới nhất...${NC}"
    local LATEST_RELEASE VERSION_NUM DOWNLOAD_URL FRP_DIR
    LATEST_RELEASE=$(curl -sf https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_RELEASE" ]; then
        echo -e "${RED}>> Lỗi: Không lấy được version FRP mới nhất. Kiểm tra kết nối mạng.${NC}"
        exit 1
    fi
    VERSION_NUM=${LATEST_RELEASE#v}
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_RELEASE}/frp_${VERSION_NUM}_linux_${FRP_ARCH}.tar.gz"
    wget -q --show-progress "$DOWNLOAD_URL" -O "/tmp/frp.tar.gz" || {
        echo -e "${RED}>> Lỗi: Download FRP thất bại.${NC}"
        exit 1
    }
    tar -xzf /tmp/frp.tar.gz -C /tmp || {
        echo -e "${RED}>> Lỗi: Giải nén FRP thất bại.${NC}"
        exit 1
    }
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"
    cp "/tmp/${FRP_DIR}/frps" /usr/local/bin/frps
    cp "/tmp/${FRP_DIR}/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc
    # Verify sau khi cài
    if ! /usr/local/bin/frpc --version >/dev/null 2>&1; then
        echo -e "${RED}>> Lỗi: Binary FRP vừa cài không chạy được. Kiểm tra kiến trúc CPU.${NC}"
        exit 1
    fi
    echo -e "${GREEN}>> Cài đặt binary FRP thành công (v${VERSION_NUM}).${NC}"
}

# ==============================================
# Function: Nhập dải port — lưu dạng array
# Format mỗi phần tử: "ps:pe:use_pp"
# ==============================================
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
            echo -e "${RED}  >> Lỗi: Port phải là số nguyên!${NC}"
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

    HAS_PP="$has_pp"
}

# ==============================================
# Function: Ghi proxy vào file config
# $1=prefix $2=port_start $3=port_end $4=dummy_ip $5=target_file $6=use_pp(y/n)
# NOTE: PP chỉ apply cho TCP, KHÔNG BAO GIỜ apply cho UDP
# FIX V13: dùng bash native loop thay $(seq) — không fork subshell
# ==============================================
append_proxies() {
    local prefix=$1
    local p_s=$2
    local p_e=$3
    local dip=$4
    local target=$5
    local use_pp=$6
    local dip_dash="${dip//./-}"
    local p

    for (( p=p_s; p<=p_e; p++ )); do
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
# Function: Check duplicate proxy name trong config
# $1=proxy_name $2=config_file
# Return 0 nếu đã tồn tại, 1 nếu chưa
# FIX V13: dùng grep -F để tránh regex false-match
# ==============================================
proxy_exists() {
    local name="$1"
    local conf="$2"
    grep -qF "name = \"${name}\"" "$conf"
}

# ==============================================
# Function: Append range với duplicate check
# Dùng chung cho cả install mode và append mode
# ==============================================
append_range_dedup() {
    local prefix=$1
    local p_s=$2
    local p_e=$3
    local dip=$4
    local target=$5
    local use_pp=$6
    local dip_dash="${dip//./-}"
    local skip_count=0
    local add_count=0
    local p

    for (( p=p_s; p<=p_e; p++ )); do
        local tcp_name="${prefix}-${dip_dash}-tcp-${p}"
        if [ -f "$target" ] && proxy_exists "$tcp_name" "$target"; then
            echo -e "${YELLOW}   >> Port ${p} đã tồn tại trong config, bỏ qua.${NC}"
            (( skip_count++ )) || true
            continue
        fi
        # Ghi trực tiếp từng port để tránh gọi lại append_proxies (loop trong loop)
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
        cat >> "$target" <<EOF

[[proxies]]
name = "${prefix}-${dip_dash}-udp-${p}"
type = "udp"
localIP = "${dip}"
localPort = ${p}
remotePort = ${p}
EOF
        (( add_count++ )) || true
    done

    echo -e "${GREEN}   >> Range ${p_s}-${p_e}: thêm ${add_count} port, bỏ qua ${skip_count} port trùng.${NC}"
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
    local proto=${2:-tcp}

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
        echo -e "${GREEN}   [UFW] Đã mở ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        echo -e "${GREEN}   [FirewallD] Đã mở ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
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
echo -e "${GREEN}${BOLD}   V13.0                               ${NC}"
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

    if [ "${#IP_LIST[@]}" -eq 0 ]; then
        echo -e "${YELLOW}>> Không tìm thấy IP global nào. Chuyển sang nhập thủ công.${NC}"
    else
        for i in "${!IP_LIST[@]}"; do
            curr_ip="${IP_LIST[$i]}"
            hint=""
            if compgen -G "/etc/frp/*.toml" > /dev/null 2>&1; then
                # FIX V13: dùng grep -F để tránh regex false-match trên IP (dấu chấm)
                file_using=$(grep -rlF "bindAddr = \"${curr_ip}\"" /etc/frp/*.toml 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                if [ -n "$file_using" ]; then
                    hint="${CYAN}[Đang dùng: $file_using]${NC}"
                fi
            fi
            echo -e "  ${YELLOW}$((i+1)).${NC} ${curr_ip} ${hint}"
        done
    fi

    read -p "Chọn IP [0=Tự gõ]: " ip_idx
    if [ "$ip_idx" == "0" ]; then
        read -p "Nhập IP: " bind_ip
    else
        bind_ip="${IP_LIST[$((ip_idx-1))]:-}"
    fi

    if [ -z "$bind_ip" ]; then
        echo -e "${RED}>> Lỗi: IP không hợp lệ.${NC}"
        exit 1
    fi

    read -p "Control Port [7000]: " ctrl_port
    ctrl_port=${ctrl_port:-7000}

    # FIX V13: ẩn token khi nhập
    read -s -p "Auth Token: " auth_token
    echo
    if [ -z "$auth_token" ]; then
        echo -e "${RED}>> Lỗi: Auth token không được để trống.${NC}"
        exit 1
    fi

    install_frp_core

    # Mở firewall cho Control Port
    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Đang mở firewall cho Control Port ${ctrl_port}...${NC}"
        firewall_open_port "$ctrl_port" "tcp"
        [ "${FIREWALLD_RELOAD}" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0
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

    # FIX V13: ẩn token khi nhập
    read -s -p "Auth Token: " auth_token
    echo
    read -p "IP local của Node này (Dummy IP) [192.168.254.1]: " DUMMY_IP
    DUMMY_IP=${DUMMY_IP:-192.168.254.1}

    if [ -z "$vps_ip" ] || [ -z "$ctrl_port" ] || [ -z "$auth_token" ]; then
        echo -e "${RED}>> Lỗi: VPS IP, Control Port, Auth Token không được để trống.${NC}"
        exit 1
    fi

    # Validate Dummy IP
    if [[ ! "$DUMMY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}>> Lỗi: Dummy IP '${DUMMY_IP}' không hợp lệ.${NC}"
        echo -e "${RED}   Phải là dạng x.x.x.x (ví dụ: 192.168.1.36)${NC}"
        exit 1
    fi

    SVC="frpc-${DUMMY_IP//./-}"
    CONF="/etc/frp/${SVC}.toml"

    MODE="install"

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

    # Setup Dummy IP trên loopback
    if ! ip addr show dev lo | grep -q "inet ${DUMMY_IP}/"; then
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
        echo -e "${YELLOW}   Lưu ý: Nếu IP này không được quản lý bởi service dummy, nó sẽ mất sau reboot!${NC}"
    fi

    # ==============================================
    # FIX V13: WS_PORT dùng 3 octet (o2+o3+o4) để tránh collision
    # với các IP cùng octet cuối nhưng khác subnet
    # Range: 40000–59999 (tránh conflict với well-known ports)
    # ==============================================
    IFS='.' read -r _o1 o2 o3 o4 <<< "$DUMMY_IP"
    WS_PORT=$(( 40000 + (o2 * 65536 + o3 * 256 + o4) % 20000 ))

    # Kiểm tra WS_PORT collision
    if ss -tlnp 2>/dev/null | grep -q ":${WS_PORT} "; then
        echo -e "${YELLOW}>> Cảnh báo: WebServer port ${WS_PORT} đang bị dùng bởi process khác!${NC}"
        echo -e "${YELLOW}   frpc có thể fail start. Kiểm tra với: ss -tlnp | grep ${WS_PORT}${NC}"
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
        # FIX V13: dùng append_range_dedup ngay cả khi install
        # để check duplicate nếu user confirm overlap range
        echo -e "${CYAN}>> Đang ghi proxy entries...${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe use_pp <<< "$r"
            append_range_dedup "mc" "$ps" "$pe" "$DUMMY_IP" "$CONF" "$use_pp"
        done

    elif [ "$MODE" == "append" ]; then
        echo -e "${CYAN}>> Đang thêm port mới vào config hiện tại...${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe use_pp <<< "$r"
            append_range_dedup "mc" "$ps" "$pe" "$DUMMY_IP" "$CONF" "$use_pp"
        done

        # Reload thay vì restart để không kick player
        echo -e "${CYAN}>> Đang reload frpc (không kick player)...${NC}"
        parse_frp_version "/usr/local/bin/frpc"
        if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
            if /usr/local/bin/frpc reload -c "$CONF"; then
                echo -e "${GREEN}>> Reload thành công!${NC}"
            else
                echo -e "${YELLOW}>> Reload thất bại, thử restart service...${NC}"
                systemctl restart "$SVC"
            fi
        else
            if /usr/local/bin/frpc reload --server_addr 127.0.0.1 --server_port "${WS_PORT}"; then
                echo -e "${GREEN}>> Reload thành công!${NC}"
            else
                echo -e "${YELLOW}>> Reload thất bại, thử restart service...${NC}"
                systemctl restart "$SVC"
            fi
        fi
    fi

    # ==============================================
    # FIX V13: Cảnh báo rõ khi mở firewall trên CLIENT node
    # (client không cần mở inbound port nếu không có public IP)
    # ==============================================
    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ℹ️  NODE NÀY CÓ FIREWALL ĐANG CHẠY (${FW})${NC}"
        echo -e "${YELLOW}║                                                              ║${NC}"
        echo -e "${YELLOW}║  FRP Client chỉ cần kết nối OUTBOUND đến VPS Server.        ║${NC}"
        echo -e "${YELLOW}║  Thường KHÔNG cần mở inbound port trên node nội bộ.         ║${NC}"
        echo -e "${YELLOW}║                                                              ║${NC}"
        echo -e "${YELLOW}║  Chỉ mở port nếu node này có public IP và bạn muốn          ║${NC}"
        echo -e "${YELLOW}║  kết nối trực tiếp (bypass FRP tunnel).                     ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        read -p "Mở inbound port trên firewall node này? (y/N): " open_fw
        if [[ "$open_fw" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}>> Đang mở firewall...${NC}"
            for r in "${CUSTOM_RANGES[@]}"; do
                IFS=':' read -r ps pe _pp <<< "$r"
                for (( p=ps; p<=pe; p++ )); do
                    firewall_open_port "$p" "tcp"
                    firewall_open_port "$p" "udp"
                done
            done
            [ "${FIREWALLD_RELOAD}" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0
            echo -e "${GREEN}>> Firewall đã được cập nhật.${NC}"
        else
            echo -e "${GREEN}>> Bỏ qua mở firewall (khuyến nghị cho node nội bộ).${NC}"
        fi
    else
        echo -e "${YELLOW}>> Không phát hiện firewall đang hoạt động.${NC}"
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

    if [ "$MODE" != "append" ]; then
        systemctl daemon-reload
        systemctl enable --now "$SVC"
    fi

    # Print summary
    echo -e ""
    echo -e "${GREEN}${BOLD}>> CLIENT ĐÃ CHẠY!${NC}"
    echo -e "${GREEN}   Service        : ${SVC}${NC}"
    echo -e "${GREEN}   Dummy IP       : ${DUMMY_IP}${NC}"
    echo -e "${GREEN}   VPS Server     : ${vps_ip}:${ctrl_port}${NC}"
    echo -e "${GREEN}   Config         : ${CONF}${NC}"
    echo -e "${GREEN}   WebServer port : ${WS_PORT}${NC}"
    echo -e ""

    # In lệnh reload đúng theo version
    parse_frp_version "/usr/local/bin/frpc"
    echo -e "${CYAN}${BOLD}>> Lệnh hot-reload (không kick player):${NC}"
    if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
        echo -e "${CYAN}   frpc reload -c ${CONF}${NC}"
        echo -e "${YELLOW}   (FRP v${FRP_MAJOR}.${FRP_MINOR} — dùng syntax mới -c)${NC}"
    else
        echo -e "${CYAN}   frpc reload --server_addr 127.0.0.1 --server_port ${WS_PORT}${NC}"
        echo -e "${YELLOW}   (FRP v${FRP_MAJOR}.${FRP_MINOR} — dùng syntax cũ; nâng lên v0.52+ để dùng lệnh ngắn hơn)${NC}"
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
        target="${LIST[$((idx-1))]:-}"

        if [ -z "$target" ]; then
            echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"
            exit 1
        fi

        target_base="${target%.service}"

        echo -e "${YELLOW}>> Đang xoá: ${target}${NC}"
        systemctl stop "$target" 2>/dev/null || true
        systemctl disable "$target" 2>/dev/null || true
        rm -f "/etc/systemd/system/${target}"
        rm -f "/etc/frp/${target_base}.toml"

        # Nếu là client → dọn Dummy IP
        if [[ "$target_base" == frpc-* ]]; then
            ip_suff="${target_base#frpc-}"
            d_svc="pterodactyl-dummy-ip-${ip_suff}"

            systemctl stop "${d_svc}.service" 2>/dev/null || true
            systemctl disable "${d_svc}.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${d_svc}.service"

            raw_ip="${ip_suff//-/.}"
            ip addr del "${raw_ip}/32" dev lo 2>/dev/null && \
                echo -e "${GREEN}>> Đã xoá Dummy IP ${raw_ip} khỏi loopback.${NC}" || \
                echo -e "${YELLOW}>> Dummy IP ${raw_ip} không còn trên loopback (có thể đã bị xoá trước).${NC}"
        fi

        systemctl daemon-reload

        # FIX V13: Hỏi có xóa binary không
        echo -e ""
        read -p "Xóa binary FRP (/usr/local/bin/frps và frpc)? (y/N): " del_bin
        if [[ "$del_bin" =~ ^[Yy]$ ]]; then
            rm -f /usr/local/bin/frps /usr/local/bin/frpc
            echo -e "${GREEN}>> Đã xóa binary FRP.${NC}"
        fi

        echo -e "${GREEN}>> Đã xoá ${target} thành công.${NC}"

    # --- Xoá sạch toàn bộ ---
    elif [ "$un_choice" == "2" ]; then
        echo -e "${RED}>> CẢNH BÁO: Thao tác này sẽ xoá TOÀN BỘ FRP và Dummy IP!${NC}"
        read -p "Xác nhận XOÁ SẠCH? (y/N): " conf_del
        if [[ ! "$conf_del" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}>> Đã huỷ.${NC}"
            exit 0
        fi

        mapfile -t ALL_SERVICES < <(systemctl list-unit-files | grep -E 'frps-|frpc-|pterodactyl-dummy-ip-' | awk '{print $1}')

        for s in "${ALL_SERVICES[@]}"; do
            s_base="${s%.service}"
            echo -e "${YELLOW}>> Xoá: ${s}${NC}"
            systemctl stop "$s" 2>/dev/null || true
            systemctl disable "$s" 2>/dev/null || true
            rm -f "/etc/systemd/system/${s}"
            rm -f "/etc/frp/${s_base}.toml"
        done

        rm -rf /etc/frp

        # Dọn tất cả Dummy IP /32 trên loopback (trừ 127.x.x.x)
        while IFS= read -r dip; do
            ip addr del "${dip}/32" dev lo 2>/dev/null && \
                echo -e "${GREEN}>> Đã xoá Dummy IP ${dip} khỏi loopback.${NC}" || true
        done < <(ip addr show dev lo | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+(?=/32)' | grep -v '^127\.')

        systemctl daemon-reload

        # FIX V13: Hỏi có xóa binary không
        echo -e ""
        read -p "Xóa binary FRP (/usr/local/bin/frps và frpc)? (y/N): " del_bin
        if [[ "$del_bin" =~ ^[Yy]$ ]]; then
            rm -f /usr/local/bin/frps /usr/local/bin/frpc
            echo -e "${GREEN}>> Đã xóa binary FRP.${NC}"
        fi

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