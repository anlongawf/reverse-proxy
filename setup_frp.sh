#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL — V17.0
# ======================================================
# Changelog từ V16.0:
#   [UX]   Đổi "Mini PC" → "Node" toàn bộ script
#   [UX]   Gộp option 2+3 thành 1 option "Thêm Node"
#   [UX]   Tự động dùng IP/port từ .server_meta (bớt bước nhập)
#   [UX]   Đơn giản hóa menu và hướng dẫn
#   [KEEP] Toàn bộ logic V16.0
# ======================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================
# Temp dir + cleanup trap
# ==============================================
TMPDIR_WORK=$(mktemp -d /tmp/frp-setup.XXXXXX)
cleanup() { rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT
trap 'echo -e "${RED}[Lỗi nghiêm trọng] Script thất bại tại dòng $LINENO — lệnh: ${BASH_COMMAND}${NC}" >&2' ERR

# ==============================================
# Audit log
# ==============================================
log_action() {
    local msg="$1"
    local logfile="/etc/frp/.audit.log"
    mkdir -p /etc/frp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$logfile" 2>/dev/null || true
}

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

FIREWALLD_RELOAD=0

# ==============================================
# Function: Load server meta AN TOÀN (không source)
# ==============================================
load_server_meta() {
    local meta_file="/etc/frp/.server_meta"
    if [[ ! -f "$meta_file" ]]; then
        return 1
    fi
    VPS_CTRL_PORT=$(grep '^VPS_CTRL_PORT=' "$meta_file" | head -1 | cut -d= -f2-) || true
    AUTH_TOKEN=$(grep '^AUTH_TOKEN=' "$meta_file" | head -1 | cut -d= -f2-) || true
    BIND_IP=$(grep '^BIND_IP=' "$meta_file" | head -1 | cut -d= -f2-) || true
    return 0
}

# ==============================================
# Function: Cài đặt binary FRP
# ==============================================
install_frp_core() {
    local force="${1:-}"
    if [ "$force" != "force" ] && \
       /usr/local/bin/frps --version >/dev/null 2>&1 && \
       /usr/local/bin/frpc --version >/dev/null 2>&1; then
        local ver
        ver=$(/usr/local/bin/frpc --version 2>/dev/null)
        echo -e "${GREEN}>> Lõi FRP đã có sẵn (${ver}), bỏ qua cài đặt.${NC}"
        return 0
    fi
    echo -e "${YELLOW}>> Đang cài đặt binary FRP mới nhất...${NC}"
    local LATEST_RELEASE VERSION_NUM DOWNLOAD_URL FRP_DIR
    LATEST_RELEASE=$(curl -sf https://api.github.com/repos/fatedier/frp/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true
    if [ -z "${LATEST_RELEASE:-}" ]; then
        echo -e "${RED}>> Lỗi: Không lấy được version FRP. Kiểm tra kết nối mạng.${NC}"
        exit 1
    fi
    VERSION_NUM=${LATEST_RELEASE#v}
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_RELEASE}/frp_${VERSION_NUM}_linux_${FRP_ARCH}.tar.gz"
    wget -q --show-progress "$DOWNLOAD_URL" -O "${TMPDIR_WORK}/frp.tar.gz" \
        || { echo -e "${RED}>> Download thất bại.${NC}"; exit 1; }
    tar -xzf "${TMPDIR_WORK}/frp.tar.gz" -C "${TMPDIR_WORK}" \
        || { echo -e "${RED}>> Giải nén thất bại.${NC}"; exit 1; }
    FRP_DIR="frp_${VERSION_NUM}_linux_${FRP_ARCH}"
    cp "${TMPDIR_WORK}/${FRP_DIR}/frps" /usr/local/bin/frps
    cp "${TMPDIR_WORK}/${FRP_DIR}/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc
    if ! /usr/local/bin/frpc --version >/dev/null 2>&1; then
        echo -e "${RED}>> Binary FRP không chạy được. Kiểm tra CPU arch.${NC}"
        exit 1
    fi
    echo -e "${GREEN}>> Cài đặt FRP thành công (v${VERSION_NUM}).${NC}"
}

# ==============================================
# Function: So sánh version FRP >= 0.52
# (dùng if/return tránh set -e crash)
# ==============================================
frp_ver_gte_052() {
    local maj="${1:-0}" min="${2:-0}"
    if ! [[ "$maj" =~ ^[0-9]+$ ]] || ! [[ "$min" =~ ^[0-9]+$ ]]; then return 1; fi
    if (( maj > 0 )); then return 0; fi
    if (( maj == 0 && min >= 52 )); then return 0; fi
    return 1
}

# ==============================================
# Function: Parse version từ binary (portable, không dùng grep -oP)
# ==============================================
parse_frp_version() {
    local bin="$1"
    local ver_full
    ver_full=$("$bin" --version 2>/dev/null) || { FRP_MAJOR=0; FRP_MINOR=0; return 1; }
    ver_full="${ver_full#v}"
    IFS='.' read -r FRP_MAJOR FRP_MINOR _ <<< "$ver_full"
    FRP_MAJOR="${FRP_MAJOR:-0}"
    FRP_MINOR="${FRP_MINOR:-0}"
}

# ==============================================
# Function: Mở firewall
# ==============================================
firewall_open_port() {
    local port=$1 proto=${2:-tcp}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
        echo -e "${GREEN}   [UFW] Mở ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        echo -e "${GREEN}   [FirewallD] Mở ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
            echo -e "${GREEN}   [iptables] Mở ${port}/${proto}${NC}"
        fi
    fi
}

# ==============================================
# Function: Đóng firewall port
# ==============================================
firewall_close_port() {
    local port=$1 proto=${2:-tcp}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
        echo -e "${YELLOW}   [UFW] Đóng ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        echo -e "${YELLOW}   [FirewallD] Đóng ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        echo -e "${YELLOW}   [iptables] Đóng ${port}/${proto}${NC}"
    fi
}

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
# Function: Reload firewalld nếu cần (an toàn với set -e)
# ==============================================
firewall_reload_if_needed() {
    if [ "${FIREWALLD_RELOAD}" -eq 1 ]; then
        if firewall-cmd --reload >/dev/null 2>&1; then
            FIREWALLD_RELOAD=0
        else
            echo -e "${YELLOW}>> Cảnh báo: firewalld reload thất bại.${NC}"
        fi
    fi
}

# ==============================================
# port_used_on_shared — dùng find tránh glob lỗi
# ==============================================
port_used_on_shared() {
    local port=$1
    find /etc/frp -maxdepth 1 -name "*.toml" -exec \
        grep -lF "remotePort = ${port}" {} \; 2>/dev/null | head -1
}

# ==============================================
# validate_ip — kiểm tra từng octet 0-255
# ==============================================
validate_ip() {
    local ip="$1"
    local octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        if (( octet > 255 )); then return 1; fi
    done
    return 0
}

# ==============================================
# Function: Validate port number
# ==============================================
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ==============================================
# Function: Validate index input (số nguyên trong range)
# ==============================================
validate_index() {
    local input="$1" max="$2"
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then return 1; fi
    if (( input < 1 || input > max )); then return 1; fi
    return 0
}

# ==============================================
# calc_ws_port — tính WS_PORT, tự tăng nếu trùng
# (thêm loop guard chống infinite loop)
# ==============================================
calc_ws_port() {
    local local_ip="$1"
    local o2 o3 o4
    IFS='.' read -r _ o2 o3 o4 <<< "$local_ip"
    local base_port=$(( 40000 + (o2 * 65536 + o3 * 256 + o4) % 15000 ))
    local candidate=$base_port
    local attempts=0
    while grep -rqF "port = ${candidate}" /etc/frp/ 2>/dev/null; do
        candidate=$(( candidate + 1 ))
        attempts=$(( attempts + 1 ))
        if (( candidate > 55000 )); then
            candidate=40000
        fi
        if (( attempts > 15001 )); then
            echo -e "${RED}>> Hết WS port trống (40000-55000).${NC}" >&2
            echo "40000"
            return 1
        fi
    done
    echo "$candidate"
}

# ==============================================
# calc_user_ctrl_port — tìm control port chưa dùng cho frps per-user
# ==============================================
calc_user_ctrl_port() {
    local base="${1:-7001}"
    local candidate=$base
    local attempts=0
    local used
    while true; do
        used=$(find /etc/frp -maxdepth 1 -name "frps-*.toml" \
            -exec grep -lF "bindPort = ${candidate}" {} \; 2>/dev/null | head -1)
        if [ -z "$used" ]; then
            break
        fi
        candidate=$(( candidate + 1 ))
        attempts=$(( attempts + 1 ))
        if (( attempts > 1000 )); then
            echo -e "${RED}>> Không tìm được control port trống.${NC}" >&2
            echo "$base"
            return 1
        fi
    done
    echo "$candidate"
}

# ==============================================
# Function: Extract ports từ config frpc (cho firewall cleanup)
# ==============================================
extract_ports_from_config() {
    local conf="$1"
    if [ -f "$conf" ]; then
        grep "^remotePort" "$conf" 2>/dev/null | grep -oE '[0-9]+' | sort -un || true
    fi
}

# ==============================================
# Function: Nhập dải port
# ==============================================
get_port_ranges() {
    local mode=$1
    CUSTOM_RANGES=()

    echo -e "\n${CYAN}${BOLD}--- Cấu hình Dải Port ---${NC}"
    if [ "$mode" == "shared" ]; then
        echo -e "  ${YELLOW}IP Chung: tất cả TCP+UDP, không PP.${NC}"
        echo -e "  ${YELLOW}Script tự kiểm tra port trùng với user khác.${NC}"
        echo -e "  ${YELLOW}Ví dụ: 19000-19200, 30000-30200, 40000-40200${NC}"
    else
        echo -e "  ${YELLOW}IP Riêng: nhập từng dải, chọn có bật PP v2 không.${NC}"
        echo -e "  ${YELLOW}PP v2 chỉ áp dụng cho TCP — UDP không bao giờ có PP.${NC}"
        echo -e "  ${CYAN}  Ví dụ:${NC}"
        echo -e "  ${CYAN}    25565       → TCP có PP (BungeeCord) + UDP${NC}"
        echo -e "  ${CYAN}    25566-25572 → TCP+UDP không PP${NC}"
        echo -e "  ${CYAN}    19132       → TCP+UDP không PP (Geyser)${NC}"
    fi
    echo ""

    while true; do
        read -p "Thêm dải port mới? (y/N): " add_more || { echo; break; }
        [[ ! "$add_more" =~ ^[Yy]$ ]] && break

        read -p "  Port bắt đầu: " p_s || { echo; break; }
        read -p "  Port kết thúc: " p_e || { echo; break; }

        if ! validate_port "$p_s" || ! validate_port "$p_e"; then
            echo -e "${RED}  >> Lỗi: Port không hợp lệ (1-65535)!${NC}"
            continue
        fi
        if [ "$p_e" -lt "$p_s" ]; then
            echo -e "${RED}  >> Lỗi: Port kết thúc phải >= Port bắt đầu!${NC}"
            continue
        fi

        # Cảnh báo port thấp
        if (( p_s < 1024 )); then
            echo -e "${YELLOW}  >> Cảnh báo: Port < 1024 cần quyền root trên backend server.${NC}"
        fi

        # Check overlap với dải đã nhập trong session này
        local overlap=0
        for r in "${CUSTOM_RANGES[@]+"${CUSTOM_RANGES[@]}"}"; do
            IFS=':' read -r ex_s ex_e _pp <<< "$r"
            if [ "$p_s" -le "$ex_e" ] && [ "$p_e" -ge "$ex_s" ]; then
                echo -e "${YELLOW}  >> Cảnh báo: Trùng với dải đã nhập ${ex_s}-${ex_e}!${NC}"
                overlap=1; break
            fi
        done
        if [ "$overlap" -eq 1 ]; then
            read -p "  Vẫn thêm? (y/N): " fa || { echo; continue; }
            [[ ! "$fa" =~ ^[Yy]$ ]] && continue
        fi

        local use_pp="n"

        if [ "$mode" == "dedicated" ]; then
            echo -e "  ${YELLOW}Dải ${p_s}-${p_e}: có dùng BungeeCord/Velocity không?${NC}"
            echo -e "  ${CYAN}  y → PP v2 bật cho TCP (BungeeCord/Velocity port)${NC}"
            echo -e "  ${CYAN}  N → TCP+UDP thuần (Paper, Fabric, Geyser, v.v.)${NC}"
            read -p "  Bật PP v2 cho dải này? (y/N): " pp_input || { echo; }
            [[ "${pp_input:-}" =~ ^[Yy]$ ]] && use_pp="y"

            if [ "$use_pp" == "y" ]; then
                echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP có PP v2, UDP không PP]${NC}"
            else
                echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP+UDP, không PP]${NC}"
            fi

        elif [ "$mode" == "shared" ]; then
            local conflict=0
            for (( p=p_s; p<=p_e; p++ )); do
                local used_by
                used_by=$(port_used_on_shared "$p")
                if [ -n "$used_by" ]; then
                    echo -e "${RED}  >> Port ${p} đã dùng bởi: $(basename "$used_by")${NC}"
                    conflict=1
                fi
            done
            if [ "$conflict" -eq 1 ]; then
                read -p "  Vẫn thêm dải này? (y/N): " fc || { echo; continue; }
                [[ ! "$fc" =~ ^[Yy]$ ]] && continue
            fi
            echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP+UDP, không PP]${NC}"
        fi

        CUSTOM_RANGES+=("${p_s}:${p_e}:${use_pp}")
    done
}

# ==============================================
# Function: Ghi proxy entries vào file config frpc
# $1=username $2=port_start $3=port_end $4=local_ip
# $5=target_file $6=use_pp(y/n)
# ==============================================
write_proxies() {
    local uname=$1 p_s=$2 p_e=$3 local_ip=$4 target=$5 use_pp=$6
    local uname_clean="${uname//[^a-zA-Z0-9_-]/-}"
    local lip_dash="${local_ip//./-}"
    local p

    for (( p=p_s; p<=p_e; p++ )); do
        # TCP
        cat >> "$target" <<EOF

[[proxies]]
name = "${uname_clean}-${lip_dash}-tcp-${p}"
type = "tcp"
localIP = "${local_ip}"
localPort = ${p}
remotePort = ${p}
EOF
        if [ "$use_pp" == "y" ]; then
            echo "transport.proxyProtocolVersion = \"v2\"" >> "$target"
        fi

        # UDP (không bao giờ có PP)
        cat >> "$target" <<EOF

[[proxies]]
name = "${uname_clean}-${lip_dash}-udp-${p}"
type = "udp"
localIP = "${local_ip}"
localPort = ${p}
remotePort = ${p}
EOF
    done
}

# ==============================================
# show_pp_guide — hướng dẫn config BungeeCord/Velocity
# ==============================================
show_pp_guide() {
    local static_ip=$1
    local W=62
    echo -e ""
    echo -e "${CYAN}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "📋 HƯỚNG DẪN GỬI CHO USER (Gói IP Riêng)"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "IP kết nối: ${static_ip}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "Nếu dùng BungeeCord/Waterfall — config.yml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "proxy_protocol: true"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "ip_forward: true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "Nếu dùng Velocity — velocity.toml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "haproxy-protocol = true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "❌ Quên config → Player KHÔNG vào được!"
    echo -e "${CYAN}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}"
}

# ==============================================
# show_node_guide — hướng dẫn cài client trên Node
# ==============================================
show_node_guide() {
    local uname=$1 local_ip=$2 vps_ip=$3 ctrl_port=$4 token=$5
    local masked_token
    if [ "${#token}" -gt 8 ]; then
        masked_token="${token:0:4}****${token: -4}"
    else
        masked_token="****"
    fi
    local W=62
    echo -e ""
    echo -e "${YELLOW}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${YELLOW}║  %-$((W-2))s║${NC}\n" "🖥️  TIẾP THEO: SSH vào Node và chạy script này"
    printf "${YELLOW}║  %-$((W-2))s║${NC}\n" ""
    printf "${YELLOW}║  %-$((W-2))s║${NC}\n" "Chọn option 4 trên Node, dùng thông tin:"
    printf "${YELLOW}║    %-10s: %-$((W-16))s║${NC}\n" "Node"     "${uname}"
    printf "${YELLOW}║    %-10s: %-$((W-16))s║${NC}\n" "VPS IP"   "${vps_ip}"
    printf "${YELLOW}║    %-10s: %-$((W-16))s║${NC}\n" "Port"     "${ctrl_port}"
    printf "${YELLOW}║    %-10s: %-$((W-16))s║${NC}\n" "Token"    "${masked_token} (xem file config)"
    printf "${YELLOW}║    %-10s: %-$((W-16))s║${NC}\n" "Local IP" "${local_ip}"
    echo -e "${YELLOW}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}"
}

# ==============================================
# list_users — lặp qua frps-user-* (1 lần / user)
# Hiển thị cả frps status cho dedicated users
# ==============================================
list_users() {
    echo -e "\n${CYAN}${BOLD}=== DANH SÁCH USER FRP ===${NC}"
    local found=0

    while IFS= read -r conf; do
        local fname uname pkg pkg_ip frps_svc_status frpc_svc_status
        fname=$(basename "$conf" .toml)
        uname="${fname#frps-user-}"

        # Detect gói từ meta comment
        pkg="IP Chung"
        pkg_ip=""
        if grep -qF "static_ip" "$conf" 2>/dev/null; then
            pkg_ip=$(awk '/static_ip/{print $NF}' "$conf" | head -1)
            [ -n "$pkg_ip" ] && pkg="IP Riêng (${pkg_ip})"
        elif grep -qF "shared_ip" "$conf" 2>/dev/null; then
            pkg_ip=$(awk '/shared_ip/{print $NF}' "$conf" | head -1)
            [ -n "$pkg_ip" ] && pkg="IP Chung (${pkg_ip})"
        fi

        # Trạng thái frps service (chỉ dedicated mới có)
        frps_svc_status=""
        if systemctl list-units --all --no-legend 2>/dev/null | grep -qF "frps-user-${uname}.service"; then
            frps_svc_status=$(systemctl is-active "frps-user-${uname}.service" 2>/dev/null || echo "inactive")
        fi

        # Trạng thái frpc service
        frpc_svc_status=$(systemctl is-active "frpc-user-${uname}.service" 2>/dev/null || echo "inactive")
        local status_color="$GREEN"
        [ "$frpc_svc_status" != "active" ] && status_color="$RED"

        echo -e "  ${BOLD}${uname}${NC} [${pkg}]"
        if [ -n "$frps_svc_status" ]; then
            local frps_color="$GREEN"
            [ "$frps_svc_status" != "active" ] && frps_color="$RED"
            echo -e "    frps   : ${frps_color}${frps_svc_status}${NC} (server instance)"
        fi
        echo -e "    frpc   : ${status_color}${frpc_svc_status}${NC}"
        echo -e "    Meta   : ${conf}"

        # Lấy port từ frpc config
        local frpc_conf="/etc/frp/frpc-user-${uname}.toml"
        if [ -f "$frpc_conf" ]; then
            echo -e "    Client : ${frpc_conf}"

            # Gom remotePort thành dải để hiển thị gọn
            local ports range_str="" prev="" start=""
            ports=$(grep "^remotePort" "$frpc_conf" 2>/dev/null \
                | grep -oE '[0-9]+' | sort -un | tr '\n' ' ' || true)
            if [ -n "$ports" ]; then
                for pp in $ports; do
                    if [ -z "$start" ]; then
                        start=$pp; prev=$pp
                    elif [ "$pp" -eq $(( prev + 1 )) ]; then
                        prev=$pp
                    else
                        if [ "$start" == "$prev" ]; then
                            range_str+="${start} "
                        else
                            range_str+="${start}-${prev} "
                        fi
                        start=$pp; prev=$pp
                    fi
                done
                if [ -n "$start" ]; then
                    if [ "$start" == "$prev" ]; then
                        range_str+="${start}"
                    else
                        range_str+="${start}-${prev}"
                    fi
                fi
                echo -e "    Ports  : ${CYAN}${range_str}${NC}"
            fi
        else
            echo -e "    ${YELLOW}(Chưa cài client — chạy option 4 trên Node)${NC}"
        fi

        echo ""
        found=1
    done < <(find /etc/frp -maxdepth 1 -name "frps-user-*.toml" 2>/dev/null | sort)

    if [ "$found" -eq 0 ]; then
        echo -e "  ${YELLOW}Chưa có user nào.${NC}"
    fi
    echo ""
}

# ==============================================
# MENU CHÍNH
# ==============================================
clear
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  MINECRAFT FRP TUNNEL MANAGER V17.0  ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════╝${NC}"
echo ""
echo "  1. Cài FRP SERVER   (chạy trên VPS)"
echo "  2. Thêm Node        (tạo tunnel cho 1 server game)"
echo "  4. Cài FRP CLIENT   (chạy trên Node/server game)"
echo "  ─────────────────────────────────────"
echo "  5. Danh sách node"
echo "  6. Restart service"
echo "  7. Xóa node"
echo "  8. Xóa SẠCH toàn bộ"
echo "  9. Update FRP binary"
echo "  ─────────────────────────────────────"
echo "  0. Thoát"
echo ""
read -p "Lựa chọn: " choice || { echo -e "\n${RED}>> EOF detected.${NC}"; exit 1; }

case "$choice" in

# ==============================================
# --- 1. CÀI FRP SERVER (VPS) ---
# ==============================================
1)
    echo -e "\n${CYAN}${BOLD}--- Cài đặt FRP Server trên VPS ---${NC}"

    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')
    echo -e "\n${CYAN}IP đang có trên máy này:${NC}"
    for i in "${!IP_LIST[@]}"; do
        echo -e "  ${YELLOW}$((i+1)).${NC} ${IP_LIST[$i]}"
    done
    echo -e "  ${YELLOW}0.${NC} Tự gõ IP"

    read -p "Chọn IP bind [0=Tự gõ]: " ip_idx || { echo; exit 1; }
    if [ "$ip_idx" == "0" ]; then
        read -p "Nhập IP: " BIND_IP || { echo; exit 1; }
    else
        if ! validate_index "$ip_idx" "${#IP_LIST[@]}"; then
            echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1
        fi
        BIND_IP="${IP_LIST[$((ip_idx-1))]}"
    fi

    if ! validate_ip "${BIND_IP:-}"; then
        echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1
    fi

    read -p "Control Port [7000]: " CTRL_PORT || { echo; exit 1; }
    CTRL_PORT=${CTRL_PORT:-7000}
    if ! validate_port "$CTRL_PORT"; then
        echo -e "${RED}>> Port không hợp lệ (1-65535).${NC}"; exit 1
    fi

    read -s -p "Auth Token (sẽ dùng cho mọi user): " AUTH_TOKEN || { echo; exit 1; }
    echo
    if [ -z "$AUTH_TOKEN" ]; then
        echo -e "${RED}>> Token không được trống.${NC}"; exit 1
    fi

    install_frp_core

    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Mở firewall control port ${CTRL_PORT}...${NC}"
        firewall_open_port "$CTRL_PORT" "tcp"
        firewall_reload_if_needed
    fi

    CONF="/etc/frp/frps-main.toml"
    cat > "$CONF" <<EOF
bindAddr = "${BIND_IP}"
bindPort = ${CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN}"
EOF
    chmod 600 "$CONF"

    cat > /etc/frp/.server_meta <<EOF
VPS_CTRL_PORT=${CTRL_PORT}
AUTH_TOKEN=${AUTH_TOKEN}
BIND_IP=${BIND_IP}
EOF
    chmod 600 /etc/frp/.server_meta

    SVC="frps-main"
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Server Main
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
    echo -e "${GREEN}${BOLD}>> FRP SERVER ĐÃ CHẠY!${NC}"
    echo -e "${GREEN}   Bind    : ${BIND_IP}:${CTRL_PORT}${NC}"
    echo -e "${GREEN}   Config  : ${CONF}${NC}"
    echo -e "${GREEN}   Service : ${SVC}${NC}"
    echo -e "${YELLOW}   Token đã lưu tại /etc/frp/.server_meta (chmod 600)${NC}"
    log_action "INSTALL: frps-main trên ${BIND_IP}:${CTRL_PORT}"
    ;;

# ==============================================
# --- 2. THÊM NODE (IP riêng hoặc IP chung) ---
# ==============================================
2)
    echo -e "\n${CYAN}${BOLD}--- Thêm Node ---${NC}"
    echo -e "  ${YELLOW}Node = server game kết nối tunnel về VPS.${NC}\n"

    VPS_CTRL_PORT="" AUTH_TOKEN="" BIND_IP=""
    if load_server_meta; then
        echo -e "${GREEN}>> Config server: ${BIND_IP}:${VPS_CTRL_PORT}${NC}"
    else
        echo -e "${RED}>> Chưa có config server — chạy option 1 trước.${NC}"; exit 1
    fi

    read -p "Tên node (vd: node01): " USERNAME || { echo; exit 1; }
    USERNAME="${USERNAME//[^a-zA-Z0-9_-]/-}"
    if [ -z "$USERNAME" ]; then echo -e "${RED}>> Tên không hợp lệ.${NC}"; exit 1; fi
    if [ "${#USERNAME}" -gt 32 ]; then echo -e "${RED}>> Tên quá dài (max 32).${NC}"; exit 1; fi
    if [ -f "/etc/frp/frps-user-${USERNAME}.toml" ]; then
        echo -e "${RED}>> Node '${USERNAME}' đã tồn tại!${NC}"; exit 1
    fi

    read -p "IP server game trên Node [127.0.0.1]: " LOCAL_IP || { echo; exit 1; }
    LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
    if ! validate_ip "$LOCAL_IP"; then echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; fi

    echo -e "\n${CYAN}Node này có IP public riêng không?${NC}"
    echo -e "  ${YELLOW}y → IP riêng: player kết nối thẳng IP đó, tạo frps riêng${NC}"
    echo -e "  ${YELLOW}N → IP chung: dùng IP VPS chính (${BIND_IP}), phân biệt bằng port${NC}"
    read -p "Dùng IP riêng? (y/N): " use_dedicated || { echo; }

    if [[ "${use_dedicated:-}" =~ ^[Yy]$ ]]; then
        # ============ DEDICATED IP ============
        read -p "IP public riêng của node (vd: 1.2.3.4): " STATIC_IP || { echo; exit 1; }
        if ! validate_ip "$STATIC_IP"; then echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; fi
        if [ "$STATIC_IP" == "$BIND_IP" ]; then
            echo -e "${RED}>> IP riêng trùng với IP chung VPS!${NC}"; exit 1
        fi
        local existing_ip_user
        existing_ip_user=$(grep -rlF "bindAddr = \"${STATIC_IP}\"" /etc/frp/frps-user-*.toml 2>/dev/null | head -1 || true)
        if [ -n "$existing_ip_user" ]; then
            echo -e "${RED}>> IP ${STATIC_IP} đã dùng bởi: $(basename "$existing_ip_user" .toml)${NC}"; exit 1
        fi
        if ! ip -4 addr show 2>/dev/null | grep -qF "$STATIC_IP"; then
            echo -e "${YELLOW}>> Cảnh báo: IP ${STATIC_IP} chưa có trên VPS.${NC}"
            read -p "Vẫn tiếp tục? (y/N): " ip_confirm || { echo; exit 1; }
            [[ ! "$ip_confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Đã huỷ.${NC}"; exit 0; }
        fi

        local_base_ctrl=$(( ${VPS_CTRL_PORT:-7000} + 1 ))
        USER_CTRL_PORT=$(calc_user_ctrl_port "$local_base_ctrl")
        echo -e "${CYAN}>> Control port: ${USER_CTRL_PORT}${NC}"

        read -s -p "Auth Token [Enter = giống server]: " TOKEN_INPUT || { echo; }
        echo
        AUTH_TOKEN_USER="${TOKEN_INPUT:-${AUTH_TOKEN:-}}"
        if [ -z "$AUTH_TOKEN_USER" ]; then echo -e "${RED}>> Token không được trống.${NC}"; exit 1; fi

        get_port_ranges "dedicated"
        if [ "${#CUSTOM_RANGES[@]}" -eq 0 ]; then echo -e "${RED}>> Chưa nhập dải port nào.${NC}"; exit 1; fi

        install_frp_core

        VPS_CONF="/etc/frp/frps-user-${USERNAME}.toml"
        cat > "$VPS_CONF" <<EOF
# === Node: ${USERNAME} | IP Riêng: ${STATIC_IP} ===
# [meta]
# username = ${USERNAME}
# package = dedicated
# static_ip = ${STATIC_IP}
# local_ip = ${LOCAL_IP}
# ctrl_port = ${USER_CTRL_PORT}

bindAddr = "${STATIC_IP}"
bindPort = ${USER_CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN_USER}"
EOF
        chmod 600 "$VPS_CONF"

        FRPS_SVC="frps-user-${USERNAME}"
        cat > "/etc/systemd/system/${FRPS_SVC}.service" <<EOF
[Unit]
Description=FRP Server — Node ${USERNAME} (${STATIC_IP})
After=network.target

[Service]
ExecStart=/usr/local/bin/frps -c ${VPS_CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        if systemctl enable --now "$FRPS_SVC" 2>/dev/null; then
            echo -e "${GREEN}>> frps ${FRPS_SVC} đã start.${NC}"
        else
            echo -e "${YELLOW}>> frps ${FRPS_SVC} chưa start được (IP chưa config?).${NC}"
        fi

        NODE_CONF="/etc/frp/frpc-user-${USERNAME}.toml"
        WS_PORT=$(calc_ws_port "$LOCAL_IP")
        cat > "$NODE_CONF" <<EOF
# === frpc — Node: ${USERNAME} | IP Riêng ===
serverAddr = "${STATIC_IP}"
serverPort = ${USER_CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN_USER}"

[webServer]
addr = "127.0.0.1"
port = ${WS_PORT}
EOF
        chmod 600 "$NODE_CONF"

        has_pp="n"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            write_proxies "$USERNAME" "$ps" "$pe" "$LOCAL_IP" "$NODE_CONF" "$pp"
            [ "$pp" == "y" ] && has_pp="y"
        done

        FW=$(detect_firewall)
        if [ "$FW" != "none" ]; then
            echo -e "${CYAN}>> Mở firewall...${NC}"
            firewall_open_port "$USER_CTRL_PORT" "tcp"
            for r in "${CUSTOM_RANGES[@]}"; do
                IFS=':' read -r ps pe _pp <<< "$r"
                for (( p=ps; p<=pe; p++ )); do
                    firewall_open_port "$p" "tcp"; firewall_open_port "$p" "udp"
                done
            done
            firewall_reload_if_needed
        fi

        echo -e "\n${GREEN}${BOLD}>> Node '${USERNAME}' đã tạo xong!${NC}"
        echo -e "${GREEN}   IP public : ${STATIC_IP}${NC}"
        echo -e "${GREEN}   Local IP  : ${LOCAL_IP}${NC}"
        echo -e "${GREEN}   CTRL Port : ${USER_CTRL_PORT}${NC}"
        echo -e "${GREEN}   Config    : ${NODE_CONF}${NC}"
        echo -e "\n${CYAN}>> Dải port:${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            [ "$pp" == "y" ] && echo -e "   ${ps}-${pe}  [TCP PP v2 + UDP]" || echo -e "   ${ps}-${pe}  [TCP+UDP]"
        done
        [ "$has_pp" == "y" ] && show_pp_guide "$STATIC_IP"
        show_node_guide "$USERNAME" "$LOCAL_IP" "$STATIC_IP" "$USER_CTRL_PORT" "$AUTH_TOKEN_USER"
        echo -e "\n${YELLOW}>> Chạy option 4 trên Node để cài client.${NC}"
        log_action "ADD_NODE: ${USERNAME} (dedicated, IP=${STATIC_IP}, ctrl=${USER_CTRL_PORT})"

    else
        # ============ SHARED IP ============
        if ! systemctl is-active --quiet frps-main.service 2>/dev/null; then
            echo -e "${YELLOW}>> Cảnh báo: frps-main chưa chạy — chạy option 1 trước.${NC}"
            read -p "Vẫn tiếp tục? (y/N): " frps_confirm || { echo; exit 1; }
            [[ ! "$frps_confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Đã huỷ.${NC}"; exit 0; }
        fi

        SHARED_IP="${BIND_IP}"
        CTRL_PORT="${VPS_CTRL_PORT:-7000}"

        read -s -p "Auth Token [Enter = giống server]: " TOKEN_INPUT || { echo; }
        echo
        AUTH_TOKEN_USER="${TOKEN_INPUT:-${AUTH_TOKEN:-}}"
        if [ -z "$AUTH_TOKEN_USER" ]; then echo -e "${RED}>> Token không được trống.${NC}"; exit 1; fi

        get_port_ranges "shared"
        if [ "${#CUSTOM_RANGES[@]}" -eq 0 ]; then echo -e "${RED}>> Chưa nhập dải port nào.${NC}"; exit 1; fi

        install_frp_core

        VPS_CONF="/etc/frp/frps-user-${USERNAME}.toml"
        cat > "$VPS_CONF" <<EOF
# === Node: ${USERNAME} | IP Chung: ${SHARED_IP} ===
# [meta]
# username = ${USERNAME}
# package = shared
# shared_ip = ${SHARED_IP}
# local_ip = ${LOCAL_IP}
# ctrl_port = ${CTRL_PORT}
EOF
        chmod 600 "$VPS_CONF"

        NODE_CONF="/etc/frp/frpc-user-${USERNAME}.toml"
        WS_PORT=$(calc_ws_port "$LOCAL_IP")
        cat > "$NODE_CONF" <<EOF
# === frpc — Node: ${USERNAME} | IP Chung ===
serverAddr = "${SHARED_IP}"
serverPort = ${CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN_USER}"

[webServer]
addr = "127.0.0.1"
port = ${WS_PORT}
EOF
        chmod 600 "$NODE_CONF"

        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe _pp <<< "$r"
            write_proxies "$USERNAME" "$ps" "$pe" "$LOCAL_IP" "$NODE_CONF" "n"
        done

        FW=$(detect_firewall)
        if [ "$FW" != "none" ]; then
            echo -e "${CYAN}>> Mở firewall...${NC}"
            for r in "${CUSTOM_RANGES[@]}"; do
                IFS=':' read -r ps pe _pp <<< "$r"
                for (( p=ps; p<=pe; p++ )); do
                    firewall_open_port "$p" "tcp"; firewall_open_port "$p" "udp"
                done
            done
            firewall_reload_if_needed
        fi

        echo -e "\n${GREEN}${BOLD}>> Node '${USERNAME}' đã tạo xong!${NC}"
        echo -e "${GREEN}   IP VPS   : ${SHARED_IP}${NC}"
        echo -e "${GREEN}   Local IP : ${LOCAL_IP}${NC}"
        echo -e "${GREEN}   Config   : ${NODE_CONF}${NC}"
        echo -e "\n${CYAN}>> Dải port (TCP+UDP):${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe _pp <<< "$r"
            echo -e "   ${ps}-${pe}"
        done
        show_node_guide "$USERNAME" "$LOCAL_IP" "$SHARED_IP" "$CTRL_PORT" "$AUTH_TOKEN_USER"
        echo -e "\n${YELLOW}>> Chạy option 4 trên Node để cài client.${NC}"
        log_action "ADD_NODE: ${USERNAME} (shared, IP=${SHARED_IP})"
    fi
    ;;

# ==============================================
# --- 3. (Đã gộp vào option 2) ---
# ==============================================
3)
    echo -e "${YELLOW}>> Option 3 đã gộp vào option 2. Dùng option 2 để thêm Node.${NC}"
    exit 0
    ;;

# ==============================================
# --- 4. CÀI FRP CLIENT (Node) ---
# ==============================================
4)
    echo -e "\n${CYAN}${BOLD}--- Cài FRP Client trên Node ---${NC}"
    echo -e "  ${YELLOW}Chạy option này trên Node sau khi đã thêm node trên VPS.${NC}\n"

    mapfile -t FRPC_CONFS < <(find /etc/frp -maxdepth 1 -name "frpc-user-*.toml" 2>/dev/null | sort)

    if [ "${#FRPC_CONFS[@]}" -eq 0 ] || [ -z "${FRPC_CONFS[0]:-}" ]; then
        echo -e "${YELLOW}>> Không tìm thấy file config frpc nào trong /etc/frp/.${NC}"
        echo -e "${YELLOW}   Copy file frpc-user-USERNAME.toml từ VPS sang /etc/frp/ trước.${NC}"
        echo -e "${YELLOW}   Ví dụ: scp root@VPS_IP:/etc/frp/frpc-user-userA.toml /etc/frp/${NC}"
        exit 1
    fi

    echo -e "${CYAN}Chọn user cần cài frpc:${NC}"
    for i in "${!FRPC_CONFS[@]}"; do
        frpc_fname=$(basename "${FRPC_CONFS[$i]}" .toml)
        frpc_uname="${frpc_fname#frpc-user-}"
        frpc_svc_status=$(systemctl is-active "frpc-user-${frpc_uname}.service" 2>/dev/null || echo "chưa cài")
        echo -e "  ${YELLOW}$((i+1)).${NC} ${frpc_uname} [${frpc_svc_status}]"
    done

    read -p "Chọn số: " fidx || { echo; exit 1; }
    if ! validate_index "$fidx" "${#FRPC_CONFS[@]}"; then
        echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1
    fi
    SELECTED_CONF="${FRPC_CONFS[$((fidx-1))]}"
    if [ ! -f "$SELECTED_CONF" ]; then
        echo -e "${RED}>> File config không tồn tại.${NC}"; exit 1
    fi

    SEL_FNAME=$(basename "$SELECTED_CONF" .toml)
    SEL_USER="${SEL_FNAME#frpc-user-}"

    install_frp_core

    # Verify config nếu FRP >= 0.52
    parse_frp_version "/usr/local/bin/frpc"
    if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
        if /usr/local/bin/frpc verify -c "$SELECTED_CONF" >/dev/null 2>&1; then
            echo -e "${GREEN}>> Config verify OK.${NC}"
        else
            echo -e "${YELLOW}>> Cảnh báo: frpc verify phát hiện vấn đề với config.${NC}"
            echo -e "${YELLOW}   Kiểm tra lại file: ${SELECTED_CONF}${NC}"
            read -p "Vẫn tiếp tục? (y/N): " verify_confirm || { echo; exit 1; }
            [[ ! "$verify_confirm" =~ ^[Yy]$ ]] && exit 1
        fi
    fi

    SVC="frpc-user-${SEL_USER}"
    cat > "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=FRP Client — User ${SEL_USER}
After=network.target

[Service]
ExecStart=/usr/local/bin/frpc -c ${SELECTED_CONF}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SVC"

    echo -e ""
    echo -e "${GREEN}${BOLD}>> frpc cho user '${SEL_USER}' đã chạy!${NC}"
    echo -e "${GREEN}   Service : ${SVC}${NC}"
    echo -e "${GREEN}   Config  : ${SELECTED_CONF}${NC}"

    echo -e ""
    echo -e "${CYAN}>> Lệnh hot-reload (không kick player):${NC}"
    if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
        echo -e "${CYAN}   frpc reload -c ${SELECTED_CONF}${NC}"
    else
        WS=$(grep -A2 "webServer" "$SELECTED_CONF" | grep "port" | grep -oE '[0-9]+' | head -1) || true
        echo -e "${CYAN}   frpc reload --server_addr 127.0.0.1 --server_port ${WS:-40000}${NC}"
    fi
    ;;

# ==============================================
# --- 5. DANH SÁCH USER ---
# ==============================================
5)
    list_users
    ;;

# ==============================================
# --- 6. RESTART SERVICE ---
# ==============================================
6)
    echo -e "\n${CYAN}${BOLD}--- Restart Service ---${NC}"

    mapfile -t SVC_LIST < <(
        {
            systemctl list-units --all --no-legend 2>/dev/null \
                | awk '{print $1}' | grep -E '^frps-main\.service$' || true
            systemctl list-units --all --no-legend 2>/dev/null \
                | awk '{print $1}' | grep -E '^frp[sc]-user-.*\.service$' || true
        } | sort -u | grep -v '^$'
    )

    # Lọc phần tử rỗng
    temp_svcs=()
    for s in "${SVC_LIST[@]+"${SVC_LIST[@]}"}"; do
        [[ -n "$s" ]] && temp_svcs+=("$s")
    done
    SVC_LIST=("${temp_svcs[@]+"${temp_svcs[@]}"}")

    if [ "${#SVC_LIST[@]}" -eq 0 ]; then
        echo -e "${YELLOW}>> Không tìm thấy service FRP nào.${NC}"; exit 0
    fi

    echo -e "${CYAN}Danh sách service:${NC}"
    for i in "${!SVC_LIST[@]}"; do
        svc="${SVC_LIST[$i]}"
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        status_color="$GREEN"; [ "$status" != "active" ] && status_color="$RED"
        echo -e "  ${YELLOW}$((i+1)).${NC} ${svc} — ${status_color}${status}${NC}"
    done
    echo -e "  ${YELLOW}0.${NC} Restart TẤT CẢ"

    read -p "Chọn số (0 = tất cả): " ridx || { echo; exit 1; }

    if [ "$ridx" == "0" ]; then
        echo -e "${CYAN}>> Restart tất cả FRP services...${NC}"
        for svc in "${SVC_LIST[@]}"; do
            if systemctl restart "$svc" 2>/dev/null; then
                echo -e "${GREEN}   ✓ ${svc}${NC}"
            else
                echo -e "${RED}   ✗ ${svc} — thất bại${NC}"
            fi
        done
        echo -e "${GREEN}${BOLD}>> Hoàn tất!${NC}"
    else
        if ! validate_index "$ridx" "${#SVC_LIST[@]}"; then
            echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1
        fi
        RSVC="${SVC_LIST[$((ridx-1))]}"
        if systemctl restart "$RSVC" 2>/dev/null; then
            echo -e "${GREEN}>> Đã restart ${RSVC}.${NC}"
        else
            echo -e "${RED}>> Restart ${RSVC} thất bại. Kiểm tra: journalctl -u ${RSVC}${NC}"
            exit 1
        fi
    fi
    ;;

# ==============================================
# --- 7. XÓA USER ---
# (Bao gồm cleanup firewall rules)
# ==============================================
7)
    echo -e "\n${RED}${BOLD}--- Xóa User ---${NC}"

    mapfile -t USER_LIST < <(
        find /etc/frp -maxdepth 1 -name "frps-user-*.toml" 2>/dev/null \
            | xargs -n1 basename 2>/dev/null \
            | sed 's/frps-user-//;s/\.toml//' \
            | sort || true
    )

    # Lọc phần tử rỗng
    temp_users=()
    for u in "${USER_LIST[@]+"${USER_LIST[@]}"}"; do
        [[ -n "$u" ]] && temp_users+=("$u")
    done
    USER_LIST=("${temp_users[@]+"${temp_users[@]}"}")

    if [ "${#USER_LIST[@]}" -eq 0 ]; then
        echo -e "${YELLOW}>> Không tìm thấy user nào.${NC}"; exit 0
    fi

    echo -e "${CYAN}Danh sách user:${NC}"
    for i in "${!USER_LIST[@]}"; do
        echo -e "  ${YELLOW}$((i+1)).${NC} ${USER_LIST[$i]}"
    done

    read -p "Chọn số user cần xóa: " didx || { echo; exit 1; }
    if ! validate_index "$didx" "${#USER_LIST[@]}"; then
        echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1
    fi
    DEL_USER="${USER_LIST[$((didx-1))]}"

    read -p "$(echo -e "${RED}>> Xác nhận xóa user '${DEL_USER}'? (y/N): ${NC}")" confirm_del || { echo; exit 1; }
    [[ ! "$confirm_del" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Đã huỷ.${NC}"; exit 0; }

    # --- Cleanup firewall rules trước khi xóa config ---
    FRPC_DEL_CONF="/etc/frp/frpc-user-${DEL_USER}.toml"
    FRPS_DEL_CONF="/etc/frp/frps-user-${DEL_USER}.toml"
    FW=$(detect_firewall)
    if [ "$FW" != "none" ] && [ -f "$FRPC_DEL_CONF" ]; then
        echo -e "${CYAN}>> Đóng firewall ports của user ${DEL_USER}...${NC}"
        DEL_PORTS=$(extract_ports_from_config "$FRPC_DEL_CONF")
        for dp in $DEL_PORTS; do
            firewall_close_port "$dp" "tcp"
            firewall_close_port "$dp" "udp"
        done
        # Đóng control port nếu là dedicated user
        if [ -f "$FRPS_DEL_CONF" ] && grep -qF "bindPort" "$FRPS_DEL_CONF" 2>/dev/null; then
            DEL_CTRL_PORT=$(awk '/^bindPort/{print $NF}' "$FRPS_DEL_CONF" | head -1)
            if [ -n "${DEL_CTRL_PORT:-}" ]; then
                firewall_close_port "$DEL_CTRL_PORT" "tcp"
            fi
        fi
        firewall_reload_if_needed
    fi

    # --- Stop/disable services ---
    for svc_type in frps frpc; do
        SVC="${svc_type}-user-${DEL_USER}.service"
        if systemctl list-units --all --no-legend 2>/dev/null | grep -qF "$SVC"; then
            systemctl stop "$SVC" 2>/dev/null || true
            systemctl disable "$SVC" 2>/dev/null || true
            rm -f "/etc/systemd/system/${SVC}"
            echo -e "${GREEN}>> Đã xóa service ${SVC}.${NC}"
        fi
    done

    rm -f "$FRPS_DEL_CONF"
    rm -f "$FRPC_DEL_CONF"
    echo -e "${GREEN}>> Đã xóa config files.${NC}"

    systemctl daemon-reload
    echo -e "${GREEN}${BOLD}>> Đã xóa user '${DEL_USER}' thành công.${NC}"
    log_action "DELETE_USER: ${DEL_USER}"
    ;;

# ==============================================
# --- 8. XÓA SẠCH TOÀN BỘ ---
# ==============================================
8)
    echo -e "\n${RED}${BOLD}=== XÓA SẠCH TOÀN BỘ ===${NC}"
    echo -e "${RED}>> CẢNH BÁO: Xóa TẤT CẢ service và config FRP!${NC}"
    read -p "Xác nhận? (y/N): " confirm_all || { echo; exit 0; }
    [[ ! "$confirm_all" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Đã huỷ.${NC}"; exit 0; }

    mapfile -t ALL_SVCS < <(
        systemctl list-units --all --no-legend 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^frps-|^frpc-' \
            | grep '\.service$' || true
    )

    for s in "${ALL_SVCS[@]+"${ALL_SVCS[@]}"}"; do
        [ -z "$s" ] && continue
        echo -e "${YELLOW}>> Xóa: ${s}${NC}"
        systemctl stop "$s"  2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/${s}"
    done

    # --- Cleanup firewall trước khi xóa config ---
    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Đóng tất cả firewall ports của FRP...${NC}"
        for conf in /etc/frp/frpc-user-*.toml; do
            [ -f "$conf" ] || continue
            CLEANUP_PORTS=$(extract_ports_from_config "$conf")
            for cp in $CLEANUP_PORTS; do
                firewall_close_port "$cp" "tcp"
                firewall_close_port "$cp" "udp"
            done
        done
        # Đóng control ports từ frps configs
        for conf in /etc/frp/frps-user-*.toml /etc/frp/frps-main.toml; do
            [ -f "$conf" ] || continue
            CTRL_P=$(awk '/^bindPort/{print $NF}' "$conf" 2>/dev/null | head -1)
            [ -n "${CTRL_P:-}" ] && firewall_close_port "$CTRL_P" "tcp"
        done
        firewall_reload_if_needed
    fi

    rm -rf /etc/frp
    systemctl daemon-reload

    read -p "Xóa binary FRP? (y/N): " del_bin || { echo; }
    if [[ "${del_bin:-}" =~ ^[Yy]$ ]]; then
        rm -f /usr/local/bin/frps /usr/local/bin/frpc
        echo -e "${GREEN}>> Đã xóa binary FRP.${NC}"
    fi

    echo -e "${RED}${BOLD}>> ĐÃ XÓA SẠCH TOÀN BỘ!${NC}"
    log_action "CLEAN_ALL: xóa toàn bộ FRP configs và services"
    ;;

# ==============================================
# --- 9. UPDATE FRP BINARY ---
# ==============================================
9)
    echo -e "\n${CYAN}${BOLD}--- Update FRP Binary ---${NC}"
    if /usr/local/bin/frpc --version >/dev/null 2>&1; then
        OLD_VER=$(/usr/local/bin/frpc --version 2>/dev/null)
        echo -e "${YELLOW}>> Version hiện tại: ${OLD_VER}${NC}"
    else
        echo -e "${YELLOW}>> Chưa cài FRP binary.${NC}"
    fi

    echo -e "${YELLOW}>> Sẽ tải và cài đặt FRP mới nhất từ GitHub.${NC}"
    read -p "Tiếp tục? (y/N): " upd_confirm || { echo; exit 1; }
    [[ ! "$upd_confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Đã huỷ.${NC}"; exit 0; }

    install_frp_core "force"

    NEW_VER=$(/usr/local/bin/frpc --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}${BOLD}>> Update hoàn tất! Version: ${NEW_VER}${NC}"
    log_action "UPDATE_FRP: ${OLD_VER:-none} -> ${NEW_VER}"

    echo -e "${YELLOW}>> Bạn nên restart tất cả FRP services (option 6 → 0).${NC}"
    ;;

# ==============================================
# --- 0. THOÁT ---
# ==============================================
0)
    echo -e "${YELLOW}>> Thoát.${NC}"; exit 0
    ;;

# ==============================================
# --- DEFAULT ---
# ==============================================
*)
    echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1
    ;;

esac