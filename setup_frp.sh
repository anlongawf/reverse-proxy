#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL — V17.1
# ======================================================
# Changelog từ V17.0:
#   [FIX]  firewall_open/close_port: thêm || true vào [ ] && echo
#          tránh set -e crash khi quiet="quiet"
#   [CLEAN] Gộp logic lặp, bỏ code thừa, gọn hơn ~15%
# ======================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

TMPDIR_WORK=$(mktemp -d /tmp/frp-setup.XXXXXX)
cleanup() { rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT
trap 'echo -e "${RED}[Lỗi] Script thất bại tại dòng $LINENO — lệnh: ${BASH_COMMAND}${NC}" >&2' ERR

log_action() {
    local logfile="/etc/frp/.audit.log"
    mkdir -p /etc/frp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$logfile" 2>/dev/null || true
}

[ "$EUID" -ne 0 ] && { echo -e "${RED}[Lỗi] Cần quyền root.${NC}"; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)          FRP_ARCH="amd64" ;;
    aarch64|arm64)   FRP_ARCH="arm64" ;;
    *)               echo -e "${RED}CPU không hỗ trợ: $ARCH${NC}"; exit 1 ;;
esac

mkdir -p /etc/frp
FIREWALLD_RELOAD=0

# ==============================================
# Helpers
# ==============================================
load_server_meta() {
    local f="/etc/frp/.server_meta"
    [[ ! -f "$f" ]] && return 1
    VPS_CTRL_PORT=$(grep '^VPS_CTRL_PORT=' "$f" | head -1 | cut -d= -f2-)
    AUTH_TOKEN=$(grep '^AUTH_TOKEN=' "$f" | head -1 | cut -d= -f2-)
    BIND_IP=$(grep '^BIND_IP=' "$f" | head -1 | cut -d= -f2-)
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local oct
    for oct in "${BASH_REMATCH[@]:1}"; do
        [ "$oct" -gt 255 ] && return 1 || true
    done
    return 0
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && return 0 || return 1
}

validate_index() {
    local input="$1" max="$2"
    [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max )) && return 0 || return 1
}

# ==============================================
# FRP binary
# ==============================================
install_frp_core() {
    local force="${1:-}"
    if [ "$force" != "force" ] && \
       /usr/local/bin/frps --version >/dev/null 2>&1 && \
       /usr/local/bin/frpc --version >/dev/null 2>&1; then
        echo -e "${GREEN}>> FRP đã có: $(/usr/local/bin/frpc --version 2>/dev/null)${NC}"
        return
    fi
    echo -e "${YELLOW}>> Đang tải FRP mới nhất...${NC}"
    local rel ver url dir
    rel=$(curl -sf https://api.github.com/repos/fatedier/frp/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true
    [ -z "${rel:-}" ] && { echo -e "${RED}>> Không lấy được version FRP.${NC}"; exit 1; }
    ver="${rel#v}"
    url="https://github.com/fatedier/frp/releases/download/${rel}/frp_${ver}_linux_${FRP_ARCH}.tar.gz"
    dir="frp_${ver}_linux_${FRP_ARCH}"
    wget -q --show-progress "$url" -O "${TMPDIR_WORK}/frp.tar.gz" || { echo -e "${RED}>> Download thất bại.${NC}"; exit 1; }
    tar -xzf "${TMPDIR_WORK}/frp.tar.gz" -C "${TMPDIR_WORK}" || { echo -e "${RED}>> Giải nén thất bại.${NC}"; exit 1; }
    cp "${TMPDIR_WORK}/${dir}/frps" /usr/local/bin/frps
    cp "${TMPDIR_WORK}/${dir}/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc
    /usr/local/bin/frpc --version >/dev/null 2>&1 || { echo -e "${RED}>> Binary không chạy được.${NC}"; exit 1; }
    echo -e "${GREEN}>> Cài FRP thành công (v${ver}).${NC}"
}

parse_frp_version() {
    local ver; ver=$("$1" --version 2>/dev/null) || { FRP_MAJOR=0; FRP_MINOR=0; return 1; }
    ver="${ver#v}"; IFS='.' read -r FRP_MAJOR FRP_MINOR _ <<< "$ver"
    FRP_MAJOR="${FRP_MAJOR:-0}"; FRP_MINOR="${FRP_MINOR:-0}"
}

frp_ver_gte_052() {
    local maj="${1:-0}" min="${2:-0}"
    [[ "$maj" =~ ^[0-9]+$ ]] && [[ "$min" =~ ^[0-9]+$ ]] || return 1
    (( maj > 0 )) && return 0
    (( maj == 0 && min >= 52 )) && return 0 || return 1
}

# ==============================================
# Firewall — FIX: thêm || true tránh set -e crash
# ==============================================
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

_fw_msg() {
    # $1=quiet $2=msg — in nếu không quiet (|| true tránh set -e)
    [ "$1" != "quiet" ] && echo -e "$2" || true
}

firewall_open_port() {
    local port=$1 proto=${2:-tcp} quiet=${3:-}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
        _fw_msg "$quiet" "${GREEN}   [UFW] Mở ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        _fw_msg "$quiet" "${GREEN}   [FirewallD] Mở ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
        _fw_msg "$quiet" "${GREEN}   [iptables] Mở ${port}/${proto}${NC}"
    fi
}

firewall_close_port() {
    local port=$1 proto=${2:-tcp} quiet=${3:-}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
        _fw_msg "$quiet" "${YELLOW}   [UFW] Đóng ${port}/${proto}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        _fw_msg "$quiet" "${YELLOW}   [FirewallD] Đóng ${port}/${proto}${NC}"
        FIREWALLD_RELOAD=1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        _fw_msg "$quiet" "${YELLOW}   [iptables] Đóng ${port}/${proto}${NC}"
    fi
}

firewall_reload_if_needed() {
    [ "${FIREWALLD_RELOAD}" -eq 1 ] || return 0
    firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0 \
        || echo -e "${YELLOW}>> Cảnh báo: firewalld reload thất bại.${NC}"
}

open_port_range() {
    # $1=start $2=end — mở TCP+UDP cho cả dải
    local p
    for (( p=$1; p<=$2; p++ )); do
        firewall_open_port "$p" "tcp" "quiet"
        firewall_open_port "$p" "udp" "quiet"
    done
}

close_port_range() {
    local p
    for (( p=$1; p<=$2; p++ )); do
        firewall_close_port "$p" "tcp" "quiet"
        firewall_close_port "$p" "udp" "quiet"
    done
}

# ==============================================
# Port helpers
# ==============================================
port_used_on_shared() {
    find /etc/frp -maxdepth 1 -name "*.toml" \
        -exec grep -lF "remotePort = ${1}" {} \; 2>/dev/null | head -1
}

calc_ws_port() {
    local ip="$1"; local o2 o3 o4
    IFS='.' read -r _ o2 o3 o4 <<< "$ip"
    local candidate=$(( 40000 + (o2 * 65536 + o3 * 256 + o4) % 15000 )) attempts=0
    while grep -rqF "port = ${candidate}" /etc/frp/ 2>/dev/null; do
        (( candidate++ )); (( candidate > 55000 )) && candidate=40000
        (( ++attempts > 15001 )) && { echo "40000"; return 1; }
    done
    echo "$candidate"
}

calc_user_ctrl_port() {
    local candidate="${1:-7001}" attempts=0
    while find /etc/frp -maxdepth 1 -name "frps-*.toml" \
            -exec grep -lF "bindPort = ${candidate}" {} \; 2>/dev/null | grep -q .; do
        (( candidate++ ))
        (( ++attempts > 1000 )) && { echo "${1:-7001}"; return 1; }
    done
    echo "$candidate"
}

extract_ports_from_config() {
    [ -f "$1" ] && grep "^remotePort" "$1" 2>/dev/null | grep -oE '[0-9]+' | sort -un || true
}

# ==============================================
# Port range input
# ==============================================
get_port_ranges() {
    local mode=$1; CUSTOM_RANGES=()
    echo -e "\n${CYAN}${BOLD}--- Cấu hình Dải Port ---${NC}"
    if [ "$mode" == "shared" ]; then
        echo -e "  ${YELLOW}IP Chung: TCP+UDP, không PP. Script tự kiểm tra port trùng.${NC}"
        echo -e "  ${YELLOW}Ví dụ: 19000-19200, 25565-25565${NC}"
    else
        echo -e "  ${YELLOW}IP Riêng: chọn có bật PP v2 (BungeeCord/Velocity) hay không.${NC}"
        echo -e "  ${CYAN}  y → TCP có PP v2 + UDP không PP${NC}"
        echo -e "  ${CYAN}  N → TCP+UDP thuần (Paper, Fabric, Geyser...)${NC}"
    fi
    echo ""

    while true; do
        read -p "Thêm dải port mới? (y/N): " add_more || { echo; break; }
        [[ ! "$add_more" =~ ^[Yy]$ ]] && break

        read -p "  Port bắt đầu: " p_s || { echo; break; }
        read -p "  Port kết thúc: " p_e || { echo; break; }

        if ! validate_port "$p_s" || ! validate_port "$p_e"; then
            echo -e "${RED}  >> Port không hợp lệ (1-65535)!${NC}"; continue
        fi
        if [ "$p_e" -lt "$p_s" ]; then
            echo -e "${RED}  >> Port kết thúc phải >= bắt đầu!${NC}"; continue
        fi
        (( p_s < 1024 )) && echo -e "${YELLOW}  >> Cảnh báo: Port < 1024 cần root.${NC}"

        # Kiểm tra overlap trong session
        local overlap=0
        for r in "${CUSTOM_RANGES[@]+"${CUSTOM_RANGES[@]}"}"; do
            IFS=':' read -r ex_s ex_e _ <<< "$r"
            if [ "$p_s" -le "$ex_e" ] && [ "$p_e" -ge "$ex_s" ]; then
                echo -e "${YELLOW}  >> Trùng với dải đã nhập ${ex_s}-${ex_e}!${NC}"
                overlap=1; break
            fi
        done
        if [ "$overlap" -eq 1 ]; then
            read -p "  Vẫn thêm? (y/N): " fa || { echo; continue; }
            [[ ! "$fa" =~ ^[Yy]$ ]] && continue
        fi

        local use_pp="n"
        if [ "$mode" == "dedicated" ]; then
            read -p "  Bật PP v2 cho dải này? (y/N): " pp_input || { echo; }
            [[ "${pp_input:-}" =~ ^[Yy]$ ]] && use_pp="y"
            [ "$use_pp" == "y" ] \
                && echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP PP v2 + UDP]${NC}" \
                || echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP+UDP]${NC}"
        elif [ "$mode" == "shared" ]; then
            local conflict=0
            for (( p=p_s; p<=p_e; p++ )); do
                local used_by; used_by=$(port_used_on_shared "$p")
                if [ -n "$used_by" ]; then
                    echo -e "${RED}  >> Port ${p} đã dùng bởi: $(basename "$used_by")${NC}"
                    conflict=1
                fi
            done
            if [ "$conflict" -eq 1 ]; then
                read -p "  Vẫn thêm? (y/N): " fc || { echo; continue; }
                [[ ! "$fc" =~ ^[Yy]$ ]] && continue
            fi
            echo -e "  ${GREEN}>> Thêm ${p_s}-${p_e} [TCP+UDP]${NC}"
        fi

        CUSTOM_RANGES+=("${p_s}:${p_e}:${use_pp}")
    done
}

# ==============================================
# Write proxy entries
# ==============================================
write_proxies() {
    local uname=$1 p_s=$2 p_e=$3 local_ip=$4 target=$5 use_pp=$6
    local uname_clean="${uname//[^a-zA-Z0-9_-]/-}"
    local lip_dash="${local_ip//./-}" p

    for (( p=p_s; p<=p_e; p++ )); do
        cat >> "$target" <<EOF

[[proxies]]
name = "${uname_clean}-${lip_dash}-tcp-${p}"
type = "tcp"
localIP = "${local_ip}"
localPort = ${p}
remotePort = ${p}
EOF
        [ "$use_pp" == "y" ] && echo 'transport.proxyProtocolVersion = "v2"' >> "$target"

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
# Helpers hiển thị
# ==============================================
show_pp_guide() {
    local ip=$1 W=62
    echo -e "\n${CYAN}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "📋 HƯỚNG DẪN PP v2 — IP Riêng"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "IP kết nối: ${ip}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "BungeeCord/Waterfall — config.yml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "proxy_protocol: true   ip_forward: true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "Velocity — velocity.toml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "haproxy-protocol = true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "❌ Quên config → Player KHÔNG vào được!"
    echo -e "${CYAN}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}"
}

generate_node_install_script() {
    local uname="$1" conf="/etc/frp/frpc-user-${1}.toml"
    [ ! -f "$conf" ] && return 1
    local b64; b64=$(base64 -w0 "$conf")
    local W=68
    echo -e "\n${YELLOW}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${YELLOW}║  %-$((W-2))s║${NC}\n" "🚀 LỆNH CÀI NHANH — CHẠY TRÊN NODE (quyền root)"
    echo -e "${YELLOW}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}\n"
    echo -e "${GREEN}mkdir -p /etc/frp && echo \"${b64}\" | base64 -d > \"/etc/frp/frpc-user-${uname}.toml\" && chmod 600 \"/etc/frp/frpc-user-${uname}.toml\" && echo -e \"\\n\\e[32m[+] Config OK\\e[0m\\n\\e[33m[!] Chạy script -> Option 4 -> Cách 1\\e[0m\"${NC}\n"
}

list_users() {
    echo -e "\n${CYAN}${BOLD}=== DANH SÁCH USER FRP ===${NC}"
    local found=0

    while IFS= read -r conf; do
        local fname uname pkg pkg_ip frps_status frpc_status sc
        fname=$(basename "$conf" .toml); uname="${fname#frps-user-}"
        pkg="IP Chung"; pkg_ip=""
        if grep -qF "static_ip" "$conf" 2>/dev/null; then
            pkg_ip=$(awk '/static_ip/{print $NF}' "$conf" | head -1)
            [ -n "$pkg_ip" ] && pkg="IP Riêng (${pkg_ip})"
        elif grep -qF "shared_ip" "$conf" 2>/dev/null; then
            pkg_ip=$(awk '/shared_ip/{print $NF}' "$conf" | head -1)
            [ -n "$pkg_ip" ] && pkg="IP Chung (${pkg_ip})"
        fi

        frpc_status=$(systemctl is-active "frpc-user-${uname}.service" 2>/dev/null || echo "inactive")
        sc="$GREEN"; [ "$frpc_status" != "active" ] && sc="$RED"

        echo -e "  ${BOLD}${uname}${NC} [${pkg}]"

        if systemctl list-units --all --no-legend 2>/dev/null | grep -qF "frps-user-${uname}.service"; then
            frps_status=$(systemctl is-active "frps-user-${uname}.service" 2>/dev/null || echo "inactive")
            local fsc="$GREEN"; [ "$frps_status" != "active" ] && fsc="$RED"
            echo -e "    frps : ${fsc}${frps_status}${NC}"
        fi
        echo -e "    frpc : ${sc}${frpc_status}${NC}"
        echo -e "    Meta : ${conf}"

        local frpc_conf="/etc/frp/frpc-user-${uname}.toml"
        if [ -f "$frpc_conf" ]; then
            echo -e "    Conf : ${frpc_conf}"
            # Hiển thị port dạng dải gọn
            local ports range_str="" start="" prev=""
            ports=$(grep "^remotePort" "$frpc_conf" 2>/dev/null \
                | grep -oE '[0-9]+' | sort -un | tr '\n' ' ' || true)
            for pp in $ports; do
                if [ -z "$start" ]; then start=$pp; prev=$pp
                elif [ "$pp" -eq $(( prev + 1 )) ]; then prev=$pp
                else
                    [ "$start" == "$prev" ] && range_str+="${start} " || range_str+="${start}-${prev} "
                    start=$pp; prev=$pp
                fi
            done
            if [ -n "$start" ]; then
                [ "$start" == "$prev" ] && range_str+="${start}" || range_str+="${start}-${prev}"
            fi
            [ -n "$range_str" ] && echo -e "    Port : ${CYAN}${range_str}${NC}"
        else
            echo -e "    ${YELLOW}(Chưa cài client — chạy option 4 trên Node)${NC}"
        fi

        echo ""; found=1
    done < <(find /etc/frp -maxdepth 1 -name "frps-user-*.toml" 2>/dev/null | sort)

    [ "$found" -eq 0 ] && echo -e "  ${YELLOW}Chưa có user nào.${NC}"
    echo ""
}

# ==============================================
# MENU CHÍNH
# ==============================================
clear
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  MINECRAFT FRP TUNNEL MANAGER V17.1  ║${NC}"
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
read -p "Lựa chọn: " choice || { echo -e "\n${RED}>> EOF.${NC}"; exit 1; }

case "$choice" in

# ==============================================
# 1. CÀI FRP SERVER
# ==============================================
1)
    echo -e "\n${CYAN}${BOLD}--- Cài đặt FRP Server trên VPS ---${NC}"

    mapfile -t IP_LIST < <(ip -4 addr show scope global | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    echo -e "\n${CYAN}IP trên máy:${NC}"
    for i in "${!IP_LIST[@]}"; do echo -e "  ${YELLOW}$((i+1)).${NC} ${IP_LIST[$i]}"; done
    echo -e "  ${YELLOW}0.${NC} Tự gõ IP"

    read -p "Chọn IP [0=Tự gõ]: " ip_idx || { echo; exit 1; }
    if [ "$ip_idx" == "0" ]; then
        read -p "Nhập IP: " BIND_IP || { echo; exit 1; }
    else
        validate_index "$ip_idx" "${#IP_LIST[@]}" || { echo -e "${RED}>> Không hợp lệ.${NC}"; exit 1; }
        BIND_IP="${IP_LIST[$((ip_idx-1))]}"
    fi
    validate_ip "${BIND_IP:-}" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }

    read -p "Control Port [7000]: " CTRL_PORT || { echo; exit 1; }
    CTRL_PORT=${CTRL_PORT:-7000}
    validate_port "$CTRL_PORT" || { echo -e "${RED}>> Port không hợp lệ.${NC}"; exit 1; }

    read -s -p "Auth Token: " AUTH_TOKEN || { echo; exit 1; }; echo
    [ -z "$AUTH_TOKEN" ] && { echo -e "${RED}>> Token trống.${NC}"; exit 1; }

    install_frp_core

    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Mở firewall port ${CTRL_PORT}...${NC}"
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

    cat > "/etc/systemd/system/frps-main.service" <<EOF
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
    systemctl enable --now frps-main

    echo -e "\n${GREEN}${BOLD}>> FRP SERVER ĐÃ CHẠY!${NC}"
    echo -e "${GREEN}   Bind    : ${BIND_IP}:${CTRL_PORT}${NC}"
    echo -e "${GREEN}   Config  : ${CONF}${NC}"
    echo -e "${YELLOW}   Token lưu tại /etc/frp/.server_meta${NC}"
    log_action "INSTALL: frps-main trên ${BIND_IP}:${CTRL_PORT}"
    ;;

# ==============================================
# 2. THÊM NODE
# ==============================================
2)
    echo -e "\n${CYAN}${BOLD}--- Thêm Node ---${NC}"

    VPS_CTRL_PORT="" AUTH_TOKEN="" BIND_IP=""
    load_server_meta || { echo -e "${RED}>> Chưa có config server — chạy option 1 trước.${NC}"; exit 1; }
    echo -e "${GREEN}>> Server: ${BIND_IP}:${VPS_CTRL_PORT}${NC}"

    read -p "Tên node (vd: node01): " USERNAME || { echo; exit 1; }
    USERNAME="${USERNAME//[^a-zA-Z0-9_-]/-}"
    [ -z "$USERNAME" ] && { echo -e "${RED}>> Tên trống.${NC}"; exit 1; }
    [ "${#USERNAME}" -gt 32 ] && { echo -e "${RED}>> Tên quá dài (max 32).${NC}"; exit 1; }
    [ -f "/etc/frp/frps-user-${USERNAME}.toml" ] && { echo -e "${RED}>> Node '${USERNAME}' đã tồn tại!${NC}"; exit 1; }

    read -p "IP server game [127.0.0.1]: " LOCAL_IP || { echo; exit 1; }
    LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
    validate_ip "$LOCAL_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }

    echo -e "\n${CYAN}Node có IP public riêng không?${NC}"
    echo -e "  ${YELLOW}y → IP riêng: player kết nối thẳng IP đó${NC}"
    echo -e "  ${YELLOW}N → IP chung: dùng IP VPS (${BIND_IP}), phân biệt bằng port${NC}"
    read -p "Dùng IP riêng? (y/N): " use_dedicated || { echo; }

    if [[ "${use_dedicated:-}" =~ ^[Yy]$ ]]; then
        # ===== DEDICATED IP =====
        read -p "IP public riêng của node: " STATIC_IP || { echo; exit 1; }
        validate_ip "$STATIC_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }
        [ "$STATIC_IP" == "$BIND_IP" ] && { echo -e "${RED}>> Trùng IP VPS!${NC}"; exit 1; }

        existing_ip
        existing_ip=$(grep -rlF "bindAddr = \"${STATIC_IP}\"" /etc/frp/frps-user-*.toml 2>/dev/null | head -1 || true)
        [ -n "$existing_ip" ] && { echo -e "${RED}>> IP đã dùng bởi: $(basename "$existing_ip" .toml)${NC}"; exit 1; }

        if ! ip -4 addr show 2>/dev/null | grep -qF "$STATIC_IP"; then
            echo -e "${YELLOW}>> IP ${STATIC_IP} chưa có trên VPS.${NC}"
            read -p "Vẫn tiếp tục? (y/N): " ipc || { echo; exit 1; }
            [[ ! "$ipc" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }
        fi

        USER_CTRL_PORT=$(calc_user_ctrl_port "$(( ${VPS_CTRL_PORT:-7000} + 1 ))")
        echo -e "${CYAN}>> Control port: ${USER_CTRL_PORT}${NC}"

        read -s -p "Auth Token [Enter = giống server]: " TOKEN_INPUT || { echo; }; echo
        AUTH_TOKEN_USER="${TOKEN_INPUT:-${AUTH_TOKEN:-}}"
        [ -z "$AUTH_TOKEN_USER" ] && { echo -e "${RED}>> Token trống.${NC}"; exit 1; }

        get_port_ranges "dedicated"
        [ "${#CUSTOM_RANGES[@]}" -eq 0 ] && { echo -e "${RED}>> Chưa nhập dải port.${NC}"; exit 1; }

        install_frp_core

        # frps config cho dedicated
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

        cat > "/etc/systemd/system/frps-user-${USERNAME}.service" <<EOF
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
        systemctl enable --now "frps-user-${USERNAME}" 2>/dev/null \
            && echo -e "${GREEN}>> frps started.${NC}" \
            || echo -e "${YELLOW}>> frps chưa start (IP chưa config?).${NC}"

        # frpc config
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
                IFS=':' read -r ps pe _ <<< "$r"
                echo -e "${GREEN}   Mở dải ${ps}-${pe}...${NC}"
                open_port_range "$ps" "$pe"
            done
            firewall_reload_if_needed
        fi

        echo -e "\n${GREEN}${BOLD}>> Node '${USERNAME}' đã tạo!${NC}"
        echo -e "${GREEN}   IP public : ${STATIC_IP}${NC}"
        echo -e "${GREEN}   Local IP  : ${LOCAL_IP}${NC}"
        echo -e "${GREEN}   CTRL Port : ${USER_CTRL_PORT}${NC}"
        echo -e "${GREEN}   Config    : ${NODE_CONF}${NC}"
        echo -e "\n${CYAN}>> Dải port:${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            [ "$pp" == "y" ] && echo -e "   ${ps}-${pe}  [TCP PP v2 + UDP]" \
                              || echo -e "   ${ps}-${pe}  [TCP+UDP]"
        done
        [ "$has_pp" == "y" ] && show_pp_guide "$STATIC_IP"
        generate_node_install_script "$USERNAME"
        log_action "ADD_NODE: ${USERNAME} (dedicated, IP=${STATIC_IP})"

    else
        # ===== SHARED IP =====
        systemctl is-active --quiet frps-main.service 2>/dev/null || {
            echo -e "${YELLOW}>> frps-main chưa chạy — chạy option 1 trước.${NC}"
            read -p "Vẫn tiếp tục? (y/N): " fc || { echo; exit 1; }
            [[ ! "$fc" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }
        }

        SHARED_IP="${BIND_IP}" CTRL_PORT="${VPS_CTRL_PORT:-7000}"

        read -s -p "Auth Token [Enter = giống server]: " TOKEN_INPUT || { echo; }; echo
        AUTH_TOKEN_USER="${TOKEN_INPUT:-${AUTH_TOKEN:-}}"
        [ -z "$AUTH_TOKEN_USER" ] && { echo -e "${RED}>> Token trống.${NC}"; exit 1; }

        get_port_ranges "shared"
        [ "${#CUSTOM_RANGES[@]}" -eq 0 ] && { echo -e "${RED}>> Chưa nhập dải port.${NC}"; exit 1; }

        install_frp_core

        # frps meta (không chạy service riêng)
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
            IFS=':' read -r ps pe _ <<< "$r"
            write_proxies "$USERNAME" "$ps" "$pe" "$LOCAL_IP" "$NODE_CONF" "n"
        done

        FW=$(detect_firewall)
        if [ "$FW" != "none" ]; then
            echo -e "${CYAN}>> Mở firewall...${NC}"
            for r in "${CUSTOM_RANGES[@]}"; do
                IFS=':' read -r ps pe _ <<< "$r"
                echo -e "${GREEN}   Mở dải ${ps}-${pe}...${NC}"
                open_port_range "$ps" "$pe"
            done
            firewall_reload_if_needed
        fi

        echo -e "\n${GREEN}${BOLD}>> Node '${USERNAME}' đã tạo!${NC}"
        echo -e "${GREEN}   IP VPS   : ${SHARED_IP}${NC}"
        echo -e "${GREEN}   Local IP : ${LOCAL_IP}${NC}"
        echo -e "${GREEN}   Config   : ${NODE_CONF}${NC}"
        echo -e "\n${CYAN}>> Dải port (TCP+UDP):${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe _ <<< "$r"
            echo -e "   ${ps}-${pe}"
        done
        generate_node_install_script "$USERNAME"
        log_action "ADD_NODE: ${USERNAME} (shared, IP=${SHARED_IP})"
    fi
    ;;

# ==============================================
# 3. (Đã gộp vào option 2)
# ==============================================
3)
    echo -e "${YELLOW}>> Option 3 đã gộp vào option 2.${NC}"; exit 0
    ;;

# ==============================================
# 4. CÀI FRP CLIENT (Node)
# ==============================================
4)
    echo -e "\n${CYAN}${BOLD}--- Cài FRP Client trên Node ---${NC}"
    echo -e "  ${YELLOW}Chạy sau khi đã thêm node trên VPS (option 2).${NC}\n"
    echo -e "  1. Dùng file config sẵn (deploy tự động / copy từ VPS)"
    echo -e "  2. Nhập cấu hình thủ công"
    read -p "Chọn cách [1/2]: " install_method || { echo; exit 1; }

    if [ "$install_method" == "2" ]; then
        echo -e "\n${CYAN}--- Nhập thủ công ---${NC}"
        read -p "Tên node: " USERNAME || { echo; exit 1; }
        USERNAME="${USERNAME//[^a-zA-Z0-9_-]/-}"
        [ -z "$USERNAME" ] && { echo -e "${RED}>> Tên trống.${NC}"; exit 1; }

        read -p "IP VPS: " VPS_IP || { echo; exit 1; }
        validate_ip "$VPS_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }

        read -p "Control Port [7000]: " CTRL_PORT || { echo; exit 1; }
        CTRL_PORT=${CTRL_PORT:-7000}

        read -s -p "Auth Token: " AUTH_TOKEN_USER || { echo; exit 1; }; echo
        [ -z "$AUTH_TOKEN_USER" ] && { echo -e "${RED}>> Token trống.${NC}"; exit 1; }

        read -p "IP server game [127.0.0.1]: " LOCAL_IP || { echo; exit 1; }
        LOCAL_IP=${LOCAL_IP:-127.0.0.1}

        echo -e "\n${CYAN}PP v2: Chỉ bật nếu BungeeCord/Velocity + IP riêng.${NC}"
        read -p "Bật PP v2? (y/N): " USE_PP || { echo; exit 1; }
        [[ "$USE_PP" =~ ^[Yy]$ ]] && use_pp="y" || use_pp="n"

        CUSTOM_RANGES=()
        while true; do
            read -p "Thêm dải port? (y/N): " am || { echo; break; }
            [[ ! "$am" =~ ^[Yy]$ ]] && break
            read -p "  Bắt đầu: " p_s || { echo; break; }
            read -p "  Kết thúc: " p_e || { echo; break; }
            validate_port "$p_s" && validate_port "$p_e" || { echo -e "${RED}  >> Port không hợp lệ!${NC}"; continue; }
            [ "$p_e" -lt "$p_s" ] && { echo -e "${RED}  >> Kết thúc phải >= bắt đầu!${NC}"; continue; }
            CUSTOM_RANGES+=("${p_s}:${p_e}:${use_pp}")
        done
        [ "${#CUSTOM_RANGES[@]}" -eq 0 ] && { echo -e "${RED}>> Cần ít nhất 1 dải port.${NC}"; exit 1; }

        SELECTED_CONF="/etc/frp/frpc-user-${USERNAME}.toml"
        WS_PORT=$(calc_ws_port "$LOCAL_IP")
        install_frp_core

        cat > "$SELECTED_CONF" <<EOF
# === frpc — Node: ${USERNAME} (Manual) ===
serverAddr = "${VPS_IP}"
serverPort = ${CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN_USER}"

[webServer]
addr = "127.0.0.1"
port = ${WS_PORT}
EOF
        chmod 600 "$SELECTED_CONF"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            write_proxies "$USERNAME" "$ps" "$pe" "$LOCAL_IP" "$SELECTED_CONF" "$pp"
        done
        echo -e "${GREEN}>> Config tạo tại $SELECTED_CONF${NC}"

    else
        mapfile -t FRPC_CONFS < <(find /etc/frp -maxdepth 1 -name "frpc-user-*.toml" 2>/dev/null | sort)
        if [ "${#FRPC_CONFS[@]}" -eq 0 ] || [ -z "${FRPC_CONFS[0]:-}" ]; then
            echo -e "${YELLOW}>> Không tìm thấy config nào. Dùng cách 2 hoặc deploy từ VPS.${NC}"; exit 1
        fi

        echo -e "${CYAN}Chọn user:${NC}"
        for i in "${!FRPC_CONFS[@]}"; do
            u="${FRPC_CONFS[$i]##*/frpc-user-}"; u="${u%.toml}"
            st; st=$(systemctl is-active "frpc-user-${u}.service" 2>/dev/null || echo "chưa cài")
            echo -e "  ${YELLOW}$((i+1)).${NC} ${u} [${st}]"
        done
        read -p "Chọn số: " fidx || { echo; exit 1; }
        validate_index "$fidx" "${#FRPC_CONFS[@]}" || { echo -e "${RED}>> Không hợp lệ.${NC}"; exit 1; }
        SELECTED_CONF="${FRPC_CONFS[$((fidx-1))]}"
        [ ! -f "$SELECTED_CONF" ] && { echo -e "${RED}>> File không tồn tại.${NC}"; exit 1; }
        install_frp_core
    fi

    SEL_USER="${SELECTED_CONF##*/frpc-user-}"; SEL_USER="${SEL_USER%.toml}"

    parse_frp_version "/usr/local/bin/frpc"
    if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
        if ! /usr/local/bin/frpc verify -c "$SELECTED_CONF" >/dev/null 2>&1; then
            echo -e "${YELLOW}>> Cảnh báo: frpc verify thất bại.${NC}"
            read -p "Vẫn tiếp tục? (y/N): " vc || { echo; exit 1; }
            [[ ! "$vc" =~ ^[Yy]$ ]] && exit 1
        else
            echo -e "${GREEN}>> Config verify OK.${NC}"
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

    echo -e "\n${GREEN}${BOLD}>> frpc '${SEL_USER}' đã chạy!${NC}"
    echo -e "${GREEN}   Service : ${SVC}${NC}"
    echo -e "${GREEN}   Config  : ${SELECTED_CONF}${NC}"
    echo -e "\n${CYAN}>> Hot-reload (không kick player):${NC}"
    if frp_ver_gte_052 "$FRP_MAJOR" "$FRP_MINOR"; then
        echo -e "${CYAN}   frpc reload -c ${SELECTED_CONF}${NC}"
    else
        WS=$(grep -A2 "webServer" "$SELECTED_CONF" | grep "port" | grep -oE '[0-9]+' | head -1 || true)
        echo -e "${CYAN}   frpc reload --server_addr 127.0.0.1 --server_port ${WS:-40000}${NC}"
    fi
    ;;

# ==============================================
# 5. DANH SÁCH
# ==============================================
5)
    list_users
    ;;

# ==============================================
# 6. RESTART SERVICE
# ==============================================
6)
    echo -e "\n${CYAN}${BOLD}--- Restart Service ---${NC}"

    mapfile -t SVC_LIST < <(
        systemctl list-units --all --no-legend 2>/dev/null | awk '{print $1}' \
            | grep -E '^(frps-main|frp[sc]-user-.+)\.service$' | sort -u || true
    )
    # Lọc rỗng
    temp=()
    for s in "${SVC_LIST[@]+"${SVC_LIST[@]}"}"; do [[ -n "$s" ]] && temp+=("$s"); done
    SVC_LIST=("${temp[@]+"${temp[@]}"}")

    [ "${#SVC_LIST[@]}" -eq 0 ] && { echo -e "${YELLOW}>> Không tìm thấy service FRP.${NC}"; exit 0; }

    echo -e "${CYAN}Danh sách service:${NC}"
    for i in "${!SVC_LIST[@]}"; do
        st; st=$(systemctl is-active "${SVC_LIST[$i]}" 2>/dev/null || echo "unknown")
        sc="$GREEN"; [ "$st" != "active" ] && sc="$RED"
        echo -e "  ${YELLOW}$((i+1)).${NC} ${SVC_LIST[$i]} — ${sc}${st}${NC}"
    done
    echo -e "  ${YELLOW}0.${NC} Restart TẤT CẢ"

    read -p "Chọn số (0=tất cả): " ridx || { echo; exit 1; }

    if [ "$ridx" == "0" ]; then
        for svc in "${SVC_LIST[@]}"; do
            systemctl restart "$svc" 2>/dev/null \
                && echo -e "${GREEN}   ✓ ${svc}${NC}" \
                || echo -e "${RED}   ✗ ${svc}${NC}"
        done
        echo -e "${GREEN}${BOLD}>> Xong!${NC}"
    else
        validate_index "$ridx" "${#SVC_LIST[@]}" || { echo -e "${RED}>> Không hợp lệ.${NC}"; exit 1; }
        RSVC="${SVC_LIST[$((ridx-1))]}"
        systemctl restart "$RSVC" 2>/dev/null \
            && echo -e "${GREEN}>> Đã restart ${RSVC}.${NC}" \
            || { echo -e "${RED}>> Thất bại. Xem: journalctl -u ${RSVC}${NC}"; exit 1; }
    fi
    ;;

# ==============================================
# 7. XÓA USER
# ==============================================
7)
    echo -e "\n${RED}${BOLD}--- Xóa Node ---${NC}"

    mapfile -t USER_LIST < <(
        find /etc/frp -maxdepth 1 -name "frps-user-*.toml" 2>/dev/null \
            | xargs -n1 basename 2>/dev/null | sed 's/frps-user-//;s/\.toml//' | sort || true
    )
    temp=()
    for u in "${USER_LIST[@]+"${USER_LIST[@]}"}"; do [[ -n "$u" ]] && temp+=("$u"); done
    USER_LIST=("${temp[@]+"${temp[@]}"}")

    [ "${#USER_LIST[@]}" -eq 0 ] && { echo -e "${YELLOW}>> Không có user nào.${NC}"; exit 0; }

    echo -e "${CYAN}Danh sách user:${NC}"
    for i in "${!USER_LIST[@]}"; do echo -e "  ${YELLOW}$((i+1)).${NC} ${USER_LIST[$i]}"; done

    read -p "Chọn số user cần xóa: " didx || { echo; exit 1; }
    validate_index "$didx" "${#USER_LIST[@]}" || { echo -e "${RED}>> Không hợp lệ.${NC}"; exit 1; }
    DEL_USER="${USER_LIST[$((didx-1))]}"

    read -p "$(echo -e "${RED}>> Xác nhận xóa '${DEL_USER}'? (y/N): ${NC}")" cd || { echo; exit 1; }
    [[ ! "$cd" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }

    FRPC_DEL="/etc/frp/frpc-user-${DEL_USER}.toml"
    FRPS_DEL="/etc/frp/frps-user-${DEL_USER}.toml"

    FW=$(detect_firewall)
    if [ "$FW" != "none" ] && [ -f "$FRPC_DEL" ]; then
        echo -e "${CYAN}>> Đóng firewall ports...${NC}"
        for dp in $(extract_ports_from_config "$FRPC_DEL"); do
            firewall_close_port "$dp" "tcp" "quiet"
            firewall_close_port "$dp" "udp" "quiet"
        done
        # Đóng control port nếu dedicated
        if [ -f "$FRPS_DEL" ]; then
            dcp; dcp=$(awk '/^bindPort/{print $NF}' "$FRPS_DEL" 2>/dev/null | head -1)
            [ -n "${dcp:-}" ] && firewall_close_port "$dcp" "tcp"
        fi
        firewall_reload_if_needed
        echo -e "${YELLOW}   Đã đóng ports của ${DEL_USER}.${NC}"
    fi

    for svc_type in frps frpc; do
        SVC="${svc_type}-user-${DEL_USER}.service"
        if systemctl list-units --all --no-legend 2>/dev/null | grep -qF "$SVC"; then
            systemctl stop "$SVC" 2>/dev/null || true
            systemctl disable "$SVC" 2>/dev/null || true
            rm -f "/etc/systemd/system/${SVC}"
            echo -e "${GREEN}>> Xóa service ${SVC}.${NC}"
        fi
    done

    rm -f "$FRPS_DEL" "$FRPC_DEL"
    systemctl daemon-reload
    echo -e "${GREEN}${BOLD}>> Đã xóa '${DEL_USER}'.${NC}"
    log_action "DELETE_NODE: ${DEL_USER}"
    ;;

# ==============================================
# 8. XÓA SẠCH
# ==============================================
8)
    echo -e "\n${RED}${BOLD}=== XÓA SẠCH TOÀN BỘ ===${NC}"
    echo -e "${RED}>> CẢNH BÁO: Xóa TẤT CẢ service và config FRP!${NC}"
    read -p "Xác nhận? (y/N): " ca || { echo; exit 0; }
    [[ ! "$ca" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }

    mapfile -t ALL_SVCS < <(
        systemctl list-units --all --no-legend 2>/dev/null | awk '{print $1}' \
            | grep -E '^frp[sc]-.+\.service$' || true
    )
    for s in "${ALL_SVCS[@]+"${ALL_SVCS[@]}"}"; do
        [ -z "$s" ] && continue
        echo -e "${YELLOW}>> Xóa: ${s}${NC}"
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/${s}"
    done

    FW=$(detect_firewall)
    if [ "$FW" != "none" ]; then
        echo -e "${CYAN}>> Đóng tất cả ports FRP...${NC}"
        for conf in /etc/frp/frpc-user-*.toml; do
            [ -f "$conf" ] || continue
            for cp in $(extract_ports_from_config "$conf"); do
                firewall_close_port "$cp" "tcp" "quiet"
                firewall_close_port "$cp" "udp" "quiet"
            done
        done
        for conf in /etc/frp/frps-user-*.toml /etc/frp/frps-main.toml; do
            [ -f "$conf" ] || continue
            cp; cp=$(awk '/^bindPort/{print $NF}' "$conf" 2>/dev/null | head -1)
            [ -n "${cp:-}" ] && firewall_close_port "$cp" "tcp"
        done
        firewall_reload_if_needed
    fi

    rm -rf /etc/frp
    systemctl daemon-reload

    read -p "Xóa binary FRP? (y/N): " db || { echo; }
    [[ "${db:-}" =~ ^[Yy]$ ]] && rm -f /usr/local/bin/frps /usr/local/bin/frpc \
        && echo -e "${GREEN}>> Đã xóa binary.${NC}"

    echo -e "${RED}${BOLD}>> ĐÃ XÓA SẠCH!${NC}"
    log_action "CLEAN_ALL"
    ;;

# ==============================================
# 9. UPDATE FRP BINARY
# ==============================================
9)
    echo -e "\n${CYAN}${BOLD}--- Update FRP Binary ---${NC}"
    OLD_VER=""
    /usr/local/bin/frpc --version >/dev/null 2>&1 \
        && OLD_VER=$(/usr/local/bin/frpc --version 2>/dev/null) \
        && echo -e "${YELLOW}>> Hiện tại: ${OLD_VER}${NC}" \
        || echo -e "${YELLOW}>> Chưa cài.${NC}"

    read -p "Tiếp tục update? (y/N): " uc || { echo; exit 1; }
    [[ ! "$uc" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }

    install_frp_core "force"
    NEW_VER=$(/usr/local/bin/frpc --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}${BOLD}>> Xong! Version: ${NEW_VER}${NC}"
    echo -e "${YELLOW}>> Nên restart tất cả services (option 6 → 0).${NC}"
    log_action "UPDATE_FRP: ${OLD_VER:-none} -> ${NEW_VER}"
    ;;

0)  echo -e "${YELLOW}>> Thoát.${NC}"; exit 0 ;;
*)  echo -e "${RED}>> Lựa chọn không hợp lệ.${NC}"; exit 1 ;;

esac