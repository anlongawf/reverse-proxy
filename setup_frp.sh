#!/bin/bash

# ======================================================
# AUTO SETUP MINECRAFT FRP TUNNEL — V17.2
# ======================================================
# Changelog từ V17.1:
#   [FIX]  18 audit fixes: set -e safety, input validation, security
#   [PERF] Firewall detection cache — tránh gọi lặp khi mở dải port
#   [SEC]  Dependency check, iptables persistence, token escaping
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

[[ "${DEBUG:-}" == "1" ]] && set -x

for _dep in curl wget base64 systemctl awk sed grep tar; do
    command -v "$_dep" >/dev/null 2>&1 || {
        echo -e "${RED}[Lỗi] Thiếu lệnh: $_dep${NC}"; exit 1
    }
done

# ==============================================
# Helpers
# ==============================================
load_server_meta() {
    local f="/etc/frp/.server_meta"
    [[ -f "$f" ]] || return 1
    VPS_CTRL_PORT=$(grep '^VPS_CTRL_PORT=' "$f" | head -1 | cut -d= -f2-) || true
    AUTH_TOKEN=$(grep '^AUTH_TOKEN=' "$f" | head -1 | cut -d= -f2-) || true
    BIND_IP=$(grep '^BIND_IP=' "$f" | head -1 | cut -d= -f2-) || true
    [[ -n "$VPS_CTRL_PORT" && -n "$AUTH_TOKEN" && -n "$BIND_IP" ]] || return 1
}

sanitize_input() {
    # Xóa escape sequences ANSI, ký tự điều khiển, và khoảng trắng thừa
    # (phát sinh khi user bấm phím mũi tên, Home, End, Delete... trong read)
    local raw="$1"
    # Strip ANSI/VT escape sequences: ESC[ ... hoặc ESC O ...
    raw=$(printf '%s' "$raw" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b[O][A-Za-z]//g; s/\x1b.//g')
    # Strip ký tự điều khiển còn lại (ASCII < 32 trừ tab), trim spaces
    raw=$(printf '%s' "$raw" | tr -d '\000-\010\013-\037\177' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s' "$raw"
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
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    (( p >= 1 && p <= 65535 )) && return 0 || return 1
}

validate_index() {
    local input="$1" max="$2"
    [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max )) && return 0 || return 1
}

# ==============================================
# Loopback IP Management
# ==============================================
detect_persist_method() {
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
    elif [ -f /etc/network/interfaces ]; then
        echo "interfaces"
    elif [ -f /etc/rc.local ]; then
        echo "rc.local"
    else
        echo "none"
    fi
}

ensure_loopback_ip() {
    local ip="$1"
    # Kiểm tra xem có phải IP Private không (127.*, 10.*, 172.16-31.*, 192.168.*)
    local is_private=0
    [[ "$ip" =~ ^127\. ]] && is_private=1
    [[ "$ip" =~ ^10\. ]] && is_private=1
    [[ "$ip" =~ ^192\.168\. ]] && is_private=1
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && is_private=1

    [ "$is_private" -eq 0 ] && return 0
    [ "$ip" == "127.0.0.1" ] && return 0

    if ip addr show 2>/dev/null | grep -qF " ${ip}/"; then
        return 0
    fi

    echo -e "${YELLOW}>> IP ${ip} chưa tồn tại trên hệ thống.${NC}"
    read -p "Bạn có muốn tự động tạo IP này trên loopback (lo) không? (y/N): " _create_lo || { echo; return 0; }
    [[ ! "${_create_lo:-}" =~ ^[Yy]$ ]] && return 0

    # Dùng netmask /32 cho IP lẻ để tránh xung đột mạng LAN
    if ! ip addr add "${ip}/32" dev lo 2>/dev/null; then
        echo -e "${RED}>> Tạo IP thất bại! Có thể do IP trùng với dải mạng LAN thật.${NC}"; return 1
    fi
    echo -e "${GREEN}>> Đã tạo IP ${ip} trên loopback.${NC}"

    local method ip_dash
    method=$(detect_persist_method)
    ip_dash="${ip//./-}"
    case "$method" in
        systemd-networkd)
            local netf="/etc/systemd/network/10-lo-alias-${ip_dash}.network"
            printf '[Match]\nName=lo\n\n[Address]\nAddress=%s/32\n' "$ip" > "$netf"
            systemctl restart systemd-networkd 2>/dev/null || true ;;
        interfaces)
            printf '\nup ip addr add %s/32 dev lo\ndown ip addr del %s/32 dev lo\n' "$ip" "$ip" >> /etc/network/interfaces ;;
        rc.local)
            sed -i "s|^exit 0|ip addr add ${ip}/32 dev lo 2>/dev/null || true\nexit 0|" /etc/rc.local ;;
    esac
    log_action "CREATE_IP_ALIAS: ${ip}"
    return 0
}

remove_loopback_ip() {
    local ip="$1"
    [ "$ip" == "127.0.0.1" ] && return 0
    ip addr show lo 2>/dev/null | grep -qF " ${ip}/" || return 0
    read -p "Gỡ bỏ IP ảo ${ip} khỏi hệ thống? (y/N): " _rem_lo || { echo; return 0; }
    [[ ! "${_rem_lo:-}" =~ ^[Yy]$ ]] && return 0
    ip addr del "${ip}/32" dev lo 2>/dev/null || true
    local ip_dash="${ip//./-}" ip_esc="${ip//./\\.}"
    local netf="/etc/systemd/network/10-lo-alias-${ip_dash}.network"
    [ -f "$netf" ] && { rm -f "$netf"; systemctl restart systemd-networkd 2>/dev/null || true; }
    [ -f /etc/network/interfaces ] && sed -i "/ip addr.*${ip_esc}/d" /etc/network/interfaces 2>/dev/null || true
    [ -f /etc/rc.local ] && sed -i "/ip addr.*${ip_esc}/d" /etc/rc.local 2>/dev/null || true
    log_action "REMOVE_IP_ALIAS: ${ip}"
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
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
    if (( maj > 0 || (maj == 0 && min >= 52) )); then return 0; fi
    return 1
}

# ==============================================
# Firewall (cached detection + iptables persistence)
# ==============================================
_FW_TYPE=""
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}
_fw_cached() { [[ -z "$_FW_TYPE" ]] && _FW_TYPE=$(detect_firewall); echo "$_FW_TYPE"; }

_fw_msg() {
    # $1=quiet $2=msg — in nếu không quiet (|| true tránh set -e)
    [ "$1" != "quiet" ] && echo -e "$2" || true
}

firewall_open_port() {
    local port=$1 proto=${2:-tcp} quiet=${3:-}
    local fw; fw=$(_fw_cached)
    case "$fw" in
        ufw)
            ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
            _fw_msg "$quiet" "${GREEN}   [UFW] Mở ${port}/${proto}${NC}" ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
            _fw_msg "$quiet" "${GREEN}   [FirewallD] Mở ${port}/${proto}${NC}"
            FIREWALLD_RELOAD=1 ;;
        iptables)
            iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
            _fw_msg "$quiet" "${GREEN}   [iptables] Mở ${port}/${proto}${NC}" ;;
    esac
}

firewall_close_port() {
    local port=$1 proto=${2:-tcp} quiet=${3:-}
    local fw; fw=$(_fw_cached)
    case "$fw" in
        ufw)
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
            _fw_msg "$quiet" "${YELLOW}   [UFW] Đóng ${port}/${proto}${NC}" ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
            _fw_msg "$quiet" "${YELLOW}   [FirewallD] Đóng ${port}/${proto}${NC}"
            FIREWALLD_RELOAD=1 ;;
        iptables)
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
            _fw_msg "$quiet" "${YELLOW}   [iptables] Đóng ${port}/${proto}${NC}" ;;
    esac
}

firewall_reload_if_needed() {
    if [ "${FIREWALLD_RELOAD}" -eq 1 ]; then
        firewall-cmd --reload >/dev/null 2>&1 && FIREWALLD_RELOAD=0 \
            || echo -e "${YELLOW}>> Cảnh báo: firewalld reload thất bại.${NC}"
    fi
    # Persist iptables rules nếu đang dùng
    local fw; fw=$(_fw_cached)
    if [ "$fw" == "iptables" ]; then
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
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
    # Đảm bảo octets là số nguyên thuần (tránh crash nếu IP bị nhiễm ký tự lạ)
    o2=$(printf '%s' "$o2" | grep -oE '^[0-9]+' || echo 0)
    o3=$(printf '%s' "$o3" | grep -oE '^[0-9]+' || echo 0)
    o4=$(printf '%s' "$o4" | grep -oE '^[0-9]+' || echo 0)
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
    if [ -f "$1" ]; then
        grep "^remotePort" "$1" 2>/dev/null | grep -oE '[0-9]+' | sort -un || true
    fi
}

# ==============================================
# Port range input
# ==============================================
get_port_ranges() {
    local mode=$1; CUSTOM_RANGES=()
    echo -e "\n${CYAN}${BOLD}--- Cấu hình Dải Port ---${NC}"
    if [ "$mode" == "shared" ]; then
        echo -e "  ${YELLOW}IP Chung: TCP+UDP thuần. Script tự kiểm tra port trùng.${NC}"
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
        (( p_s < 1024 )) && echo -e "${YELLOW}  >> Cảnh báo: Port < 1024 cần root.${NC}" || true

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
    local ip=$1 W=66
    echo -e "\n${CYAN}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "📋 HƯỚNG DẪN BẬT PP v2 PHÍA SERVER GAME"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "IP kết nối: ${ip}"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "▶ Paper (1.19+) — config/paper-global.yml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "proxies:"
    printf "${CYAN}║      %-$((W-6))s║${NC}\n" "proxy-protocol: true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "▶ BungeeCord/Waterfall — config.yml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "proxy_protocol: true   ip_forward: true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "▶ Velocity — velocity.toml:"
    printf "${CYAN}║    %-$((W-4))s║${NC}\n" "haproxy-protocol = true"
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" ""
    printf "${CYAN}║  %-$((W-2))s║${NC}\n" "❌ Quên config phía server → Player KHÔNG vào được!"
    echo -e "${CYAN}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}"
}

generate_node_install_script() {
    local uname="$1" conf="/etc/frp/frpc-user-${1}.toml"
    [[ -f "$conf" ]] || return 1
    local b64; b64=$(base64 -w0 "$conf")
    # Trích xuất localIP để embed bước tạo loopback (chỉ 127.x.x.x)
    local local_ip lo_cmd=""
    local_ip=$(grep 'localIP' "$conf" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "${local_ip:-}" ] && [ "${local_ip}" != "127.0.0.1" ]; then
        # Check nếu là IP riêng
        local is_p=0
        [[ "$local_ip" =~ ^127\. ]] && is_p=1
        [[ "$local_ip" =~ ^10\. ]] && is_p=1
        [[ "$local_ip" =~ ^192\.168\. ]] && is_p=1
        [[ "$local_ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && is_p=1

        if [ "$is_p" -eq 1 ]; then
            local ip_dash="${local_ip//./-}"
            lo_cmd=" && _LO='${local_ip}' && if ! ip addr show 2>/dev/null | grep -qF \" \${_LO}/\"; then ip addr add \${_LO}/32 dev lo 2>/dev/null || true && { if systemctl is-active --quiet systemd-networkd 2>/dev/null; then mkdir -p /etc/systemd/network && printf '[Match]\\nName=lo\\n\\n[Address]\\nAddress=%s/32\\n' \"\${_LO}\" > /etc/systemd/network/10-lo-alias-${ip_dash}.network && systemctl restart systemd-networkd 2>/dev/null || true; elif [ -f /etc/network/interfaces ] && ! grep -qF \"\${_LO}\" /etc/network/interfaces 2>/dev/null; then printf '\\nup ip addr add %s/32 dev lo\\ndown ip addr del %s/32 dev lo\\n' \"\${_LO}\" \"\${_LO}\" >> /etc/network/interfaces; elif [ -f /etc/rc.local ]; then sed -i \"s|^exit 0|ip addr add \${_LO}/32 dev lo 2>/dev/null || true\\nexit 0|\" /etc/rc.local; fi; } && echo -e \"\\e[32m[+] IP ảo \${_LO} đã tạo\\e[0m\"; fi"
        fi
    fi
    local W=68
    echo -e "\n${YELLOW}╔$(printf '═%.0s' $(seq 1 "$W"))╗${NC}"
    printf "${YELLOW}║  %-$((W-2))s║${NC}\n" "🚀 LỆNH CÀI NHANH — CHẠY TRÊN NODE (quyền root)"
    echo -e "${YELLOW}╚$(printf '═%.0s' $(seq 1 "$W"))╝${NC}\n"
    echo -e "${GREEN}mkdir -p /etc/frp && echo \"${b64}\" | base64 -d > \"/etc/frp/frpc-user-${uname}.toml\" && chmod 600 \"/etc/frp/frpc-user-${uname}.toml\"${lo_cmd} && echo -e \"\\n\\e[32m[+] Config OK\\e[0m\\n\\e[33m[!] Chạy script -> Option 4 -> Cách 1\\e[0m\"${NC}\n"
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

        echo -e "\n${BOLD}${uname}${NC} [${pkg}]"

        if systemctl list-units --all --no-legend 2>/dev/null | grep -qF "frps-user-${uname}.service"; then
            frps_status=$(systemctl is-active "frps-user-${uname}.service" 2>/dev/null || echo "inactive")
            local fsc="$GREEN"; [ "$frps_status" != "active" ] && fsc="$RED"
            echo -e "  frps : ${fsc}${frps_status}${NC}"
        fi
        echo -e "  frpc : ${sc}${frpc_status}${NC}"
        echo -e "  Meta : ${conf}"

        local frpc_conf="/etc/frp/frpc-user-${uname}.toml"
        if [ -f "$frpc_conf" ]; then
            echo -e "  Conf : ${frpc_conf}"
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
            [ -n "$range_str" ] && echo -e "  Port : ${CYAN}${range_str}${NC}"
        else
            echo -e "  ${YELLOW}(Chưa cài client — chạy option 4 trên Node)${NC}"
        fi

        found=1
    done < <(find /etc/frp -maxdepth 1 -name "frps-user-*.toml" 2>/dev/null | sort)

    # Scan frpc-user-*.toml mồ côi (không có frps-user-*.toml tương ứng)
    while IFS= read -r frpc_conf; do
        local fname uname
        fname=$(basename "$frpc_conf" .toml); uname="${fname#frpc-user-}"
        # Bỏ qua nếu đã có metadata
        [ -f "/etc/frp/frps-user-${uname}.toml" ] && continue

        local vps_ip ctrl_port local_ip
        vps_ip=$(grep '^serverAddr' "$frpc_conf" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        ctrl_port=$(grep '^serverPort' "$frpc_conf" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
        local_ip=$(grep 'localIP' "$frpc_conf" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

        # Tự tạo metadata để lần sau không cần scan lại
        cat > "/etc/frp/frps-user-${uname}.toml" <<EOF
# === Node: ${uname} | Auto-Recovered ===
# [meta]
# username = ${uname}
# package = recovered
# shared_ip = ${vps_ip:-unknown}
# local_ip = ${local_ip:-127.0.0.1}
# ctrl_port = ${ctrl_port:-7000}
EOF
        chmod 600 "/etc/frp/frps-user-${uname}.toml"

        local frpc_status
        frpc_status=$(systemctl is-active "frpc-user-${uname}.service" 2>/dev/null || echo "inactive")
        local sc="$GREEN"; [ "$frpc_status" != "active" ] && sc="$RED"

        echo -e "\n${BOLD}${uname}${NC} [${YELLOW}Recovered${NC}] (VPS: ${vps_ip:-?}:${ctrl_port:-?})"
        echo -e "  frpc : ${sc}${frpc_status}${NC}"
        echo -e "  Conf : ${frpc_conf}"

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
        [ -n "$range_str" ] && echo -e "  Port : ${CYAN}${range_str}${NC}"
        echo -e "  ${GREEN}>> Đã tự động tạo metadata cho node này.${NC}"
        log_action "RECOVER_META: ${uname}"
        found=1
    done < <(find /etc/frp -maxdepth 1 -name "frpc-user-*.toml" 2>/dev/null | sort)

    [ "$found" -eq 0 ] && echo -e "  ${YELLOW}Chưa có user nào.${NC}"
    echo ""
}

# ==============================================
# MENU CHÍNH
# ==============================================
clear
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  MINECRAFT FRP TUNNEL MANAGER V17.2  ║${NC}"
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
        BIND_IP=$(sanitize_input "$BIND_IP")
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
    if [ -f "$CONF" ]; then
        echo -e "${YELLOW}>> frps-main.toml đã tồn tại — ghi đè sẽ restart service!${NC}"
        read -p "Tiếp tục ghi đè? (y/N): " ow || { echo; exit 1; }
        [[ ! "$ow" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }
    fi
    cat > "$CONF" <<EOF
bindAddr = "${BIND_IP}"
bindPort = ${CTRL_PORT}

[auth]
method = "token"
token = "${AUTH_TOKEN}"
EOF
    chmod 600 "$CONF"

    printf 'VPS_CTRL_PORT=%s\nAUTH_TOKEN=%s\nBIND_IP=%s\n' \
        "$CTRL_PORT" "$AUTH_TOKEN" "$BIND_IP" > /etc/frp/.server_meta
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
    systemctl stop frps-main 2>/dev/null || true
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
    LOCAL_IP=$(sanitize_input "${LOCAL_IP:-127.0.0.1}")
    validate_ip "$LOCAL_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }

    echo -e "\n${CYAN}Node có IP public riêng không?${NC}"
    echo -e "  ${YELLOW}y → IP riêng: player kết nối thẳng IP đó${NC}"
    echo -e "  ${YELLOW}N → IP chung: dùng IP VPS (${BIND_IP}), phân biệt bằng port${NC}"
    read -p "Dùng IP riêng? (y/N): " use_dedicated || { echo; }

    if [[ "${use_dedicated:-}" =~ ^[Yy]$ ]]; then
        # ===== DEDICATED IP =====
        read -p "IP public riêng của node: " STATIC_IP || { echo; exit 1; }
        STATIC_IP=$(sanitize_input "$STATIC_IP")
        validate_ip "$STATIC_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }
        [ "$STATIC_IP" == "$BIND_IP" ] && { echo -e "${RED}>> Trùng IP VPS!${NC}"; exit 1; }

        # FIX: bỏ dòng "existing_ip" thừa, khai báo trực tiếp
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
        if [ "$has_pp" == "y" ]; then
            show_pp_guide "$STATIC_IP"
        fi
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

        has_pp="n"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            write_proxies "$USERNAME" "$ps" "$pe" "$LOCAL_IP" "$NODE_CONF" "$pp"
            [ "$pp" == "y" ] && has_pp="y"
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
        echo -e "\n${CYAN}>> Dải port:${NC}"
        for r in "${CUSTOM_RANGES[@]}"; do
            IFS=':' read -r ps pe pp <<< "$r"
            [ "$pp" == "y" ] && echo -e "   ${ps}-${pe}  [TCP PP v2 + UDP]" \
                             || echo -e "   ${ps}-${pe}  [TCP+UDP thuần]"
        done
        if [ "$has_pp" == "y" ]; then
            show_pp_guide "$SHARED_IP"
        fi
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
    install_method="${install_method:-1}"
    [[ ! "$install_method" =~ ^[12]$ ]] && { echo -e "${RED}>> Chỉ nhập 1 hoặc 2.${NC}"; exit 1; }

    if [ "$install_method" == "2" ]; then
        echo -e "\n${CYAN}--- Nhập thủ công ---${NC}"
        read -p "Tên node: " USERNAME || { echo; exit 1; }
        USERNAME="${USERNAME//[^a-zA-Z0-9_-]/-}"
        [ -z "$USERNAME" ] && { echo -e "${RED}>> Tên trống.${NC}"; exit 1; }

        read -p "IP VPS: " VPS_IP || { echo; exit 1; }
        VPS_IP=$(sanitize_input "$VPS_IP")
        validate_ip "$VPS_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }

        read -p "Control Port [7000]: " CTRL_PORT || { echo; exit 1; }
        CTRL_PORT=${CTRL_PORT:-7000}
        validate_port "$CTRL_PORT" || { echo -e "${RED}>> Port không hợp lệ.${NC}"; exit 1; }

        read -s -p "Auth Token: " AUTH_TOKEN_USER || { echo; exit 1; }; echo
        [ -z "$AUTH_TOKEN_USER" ] && { echo -e "${RED}>> Token trống.${NC}"; exit 1; }

        read -p "IP server game [127.0.0.1]: " LOCAL_IP || { echo; exit 1; }
        LOCAL_IP=$(sanitize_input "${LOCAL_IP:-127.0.0.1}")
        validate_ip "$LOCAL_IP" || { echo -e "${RED}>> IP không hợp lệ.${NC}"; exit 1; }
        ensure_loopback_ip "$LOCAL_IP" || true

        echo -e "\n${CYAN}PP v2: Truyền real IP của player qua tunnel đến server game.${NC}"
        echo -e "${CYAN}  Paper: config/paper-global.yml → proxies.proxy-protocol: true${NC}"
        echo -e "${CYAN}  BungeeCord: config.yml → proxy_protocol: true + ip_forward: true${NC}"
        echo -e "${CYAN}  Velocity: velocity.toml → haproxy-protocol = true${NC}"
        echo -e "${RED}  ❌ KHÔNG bật nếu server game chưa config → player không vào được!${NC}"
        read -p "Bật PP v2? (y/N): " USE_PP || { echo; exit 1; }
        [[ "$USE_PP" =~ ^[Yy]$ ]] && use_pp="y" || use_pp="n"

        CUSTOM_RANGES=()
        while true; do
            if [ "${#CUSTOM_RANGES[@]}" -eq 0 ]; then
                read -p "Nhập dải port (y để thêm): " am || { echo; break; }
                if [[ ! "$am" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}  >> Bạn cần thêm ít nhất 1 dải port. Gõ y để thêm.${NC}"
                    continue
                fi
            else
                read -p "Thêm dải port nữa? (y/N): " am || { echo; break; }
                [[ ! "$am" =~ ^[Yy]$ ]] && break
            fi
            read -p "  Port bắt đầu: " p_s || { echo; break; }
            read -p "  Port kết thúc (= bắt đầu nếu chỉ 1 port): " p_e || { echo; break; }
            p_e="${p_e:-$p_s}"
            validate_port "$p_s" && validate_port "$p_e" || { echo -e "${RED}  >> Port không hợp lệ (1-65535)!${NC}"; continue; }
            [ "$p_e" -lt "$p_s" ] && { echo -e "${RED}  >> Kết thúc phải >= bắt đầu!${NC}"; continue; }
            CUSTOM_RANGES+=("${p_s}:${p_e}:${use_pp}")
            echo -e "${GREEN}  >> Đã thêm: ${p_s}-${p_e}${NC}"
        done
        [ "${#CUSTOM_RANGES[@]}" -eq 0 ] && { echo -e "${RED}>> Cần ít nhất 1 dải port.${NC}"; exit 1; }

        SELECTED_CONF="/etc/frp/frpc-user-${USERNAME}.toml"
        if [ -f "$SELECTED_CONF" ]; then
            echo -e "${YELLOW}>> Config đã tồn tại: $SELECTED_CONF${NC}"
            read -p "Ghi đè? (y/N): " ow || { echo; exit 1; }
            [[ ! "$ow" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }
        fi
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

        # Tạo file metadata để Option 5/7 nhận diện được node này
        META_CONF="/etc/frp/frps-user-${USERNAME}.toml"
        cat > "$META_CONF" <<EOF
# === Node: ${USERNAME} | Manual Setup ===
# [meta]
# username = ${USERNAME}
# package = manual
# shared_ip = ${VPS_IP}
# local_ip = ${LOCAL_IP}
# ctrl_port = ${CTRL_PORT}
EOF
        chmod 600 "$META_CONF"

        echo -e "${GREEN}>> Config tạo tại $SELECTED_CONF${NC}"
        log_action "MANUAL_SETUP: ${USERNAME} (VPS=${VPS_IP}:${CTRL_PORT}, Local=${LOCAL_IP})"

    else
        mapfile -t FRPC_CONFS < <(find /etc/frp -maxdepth 1 -name "frpc-user-*.toml" 2>/dev/null | sort)
        if [ "${#FRPC_CONFS[@]}" -eq 0 ] || [ -z "${FRPC_CONFS[0]:-}" ]; then
            echo -e "${YELLOW}>> Không tìm thấy config nào. Dùng cách 2 hoặc deploy từ VPS.${NC}"; exit 1
        fi

        echo -e "${CYAN}Chọn user:${NC}"
        for i in "${!FRPC_CONFS[@]}"; do
            u="${FRPC_CONFS[$i]##*/frpc-user-}"; u="${u%.toml}"
            # FIX: bỏ "st;" thừa, khai báo biến trực tiếp
            local_st=$(systemctl is-active "frpc-user-${u}.service" 2>/dev/null || echo "chưa cài")
            echo -e "  ${YELLOW}$((i+1)).${NC} ${u} [${local_st}]"
        done
        read -p "Chọn số: " fidx || { echo; exit 1; }
        validate_index "$fidx" "${#FRPC_CONFS[@]}" || { echo -e "${RED}>> Không hợp lệ.${NC}"; exit 1; }
        SELECTED_CONF="${FRPC_CONFS[$((fidx-1))]}"
        [ ! -f "$SELECTED_CONF" ] && { echo -e "${RED}>> File không tồn tại.${NC}"; exit 1; }
        install_frp_core
        # Auto-detect loopback IP từ config và tạo nếu chưa có
        _conf_lip=$(grep 'localIP' "$SELECTED_CONF" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        [ -n "${_conf_lip:-}" ] && ensure_loopback_ip "$_conf_lip" || true
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
        WS=$(grep -A2 "webServer" "$SELECTED_CONF" 2>/dev/null | grep "port" | grep -oE '[0-9]+' | head -1) || true
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
        st=$(systemctl is-active "${SVC_LIST[$i]}" 2>/dev/null || echo "unknown")
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

    read -p "$(echo -e "${RED}>> Xác nhận xóa '${DEL_USER}'? (y/N): ${NC}")" del_confirm || { echo; exit 1; }
    [[ ! "$del_confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}>> Huỷ.${NC}"; exit 0; }

    FRPC_DEL="/etc/frp/frpc-user-${DEL_USER}.toml"
    FRPS_DEL="/etc/frp/frps-user-${DEL_USER}.toml"

    # Xóa loopback IP nếu có
    if [ -f "$FRPC_DEL" ]; then
        _del_lip=$(grep 'localIP' "$FRPC_DEL" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        [ -n "${_del_lip:-}" ] && remove_loopback_ip "$_del_lip" || true
    fi

    FW=$(detect_firewall)
    if [ "$FW" != "none" ] && [ -f "$FRPC_DEL" ]; then
        echo -e "${CYAN}>> Đóng firewall ports...${NC}"
        for dp in $(extract_ports_from_config "$FRPC_DEL"); do
            firewall_close_port "$dp" "tcp" "quiet"
            firewall_close_port "$dp" "udp" "quiet"
        done
        # Đóng control port nếu dedicated
        if [ -f "$FRPS_DEL" ]; then
            dcp=$(awk '/^bindPort/{print $NF}' "$FRPS_DEL" 2>/dev/null | head -1)
            [ -n "${dcp:-}" ] && firewall_close_port "$dcp" "tcp"
        fi
        firewall_reload_if_needed
        echo -e "${YELLOW}   Đã đóng ports của ${DEL_USER}.${NC}"
    fi

    for svc_type in frps frpc; do
        SVC="${svc_type}-user-${DEL_USER}.service"
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" 2>/dev/null || true
        if [ -f "/etc/systemd/system/${SVC}" ]; then
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
            for cp_val in $(extract_ports_from_config "$conf"); do
                firewall_close_port "$cp_val" "tcp" "quiet"
                firewall_close_port "$cp_val" "udp" "quiet"
            done
        done
        # FIX: đổi tên biến từ "cp" (trùng lệnh cp) sang "bind_cp"
        for conf in /etc/frp/frps-user-*.toml /etc/frp/frps-main.toml; do
            [ -f "$conf" ] || continue
            bind_cp=$(awk '/^bindPort/{print $NF}' "$conf" 2>/dev/null | head -1)
            [ -n "${bind_cp:-}" ] && firewall_close_port "$bind_cp" "tcp"
        done
        firewall_reload_if_needed
    fi

    # Backup audit log + ghi log TRƯỚC khi xóa
    if [ -f /etc/frp/.audit.log ]; then
        cp /etc/frp/.audit.log "/tmp/frp-audit-$(date +%s).log" 2>/dev/null || true
        echo -e "${CYAN}>> Audit log đã backup tại /tmp/frp-audit-*.log${NC}"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLEAN_ALL" >> /etc/frp/.audit.log 2>/dev/null || true

    # Xóa orphaned service files (có thể chưa load vào systemd)
    for _sf in /etc/systemd/system/frp{s,c}-*.service; do
        [ -f "$_sf" ] || continue
        rm -f "$_sf"
        echo -e "${YELLOW}>> Xóa file: ${_sf}${NC}"
    done

    rm -rf /etc/frp
    systemctl daemon-reload

    read -p "Xóa binary FRP? (y/N): " db || { echo; }
    [[ "${db:-}" =~ ^[Yy]$ ]] && rm -f /usr/local/bin/frps /usr/local/bin/frpc \
        && echo -e "${GREEN}>> Đã xóa binary.${NC}"

    echo -e "${RED}${BOLD}>> ĐÃ XÓA SẠCH!${NC}"
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