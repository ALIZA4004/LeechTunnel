SCRIPT_VERSION="v1.0.0"
service_dir="/etc/systemd/system"
config_dir="/root/leech"
CERT_DIR="/root/leech/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    sleep 1
    exit 1
fi
colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"
    local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
    local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
    local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
    local color_code
    case $color in
        black) color_code=$black ;; red) color_code=$red ;;
        green) color_code=$green ;; yellow) color_code=$yellow ;;
        blue) color_code=$blue ;; magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;; white) color_code=$white ;;
        *) color_code=$reset ;;
    esac
    local style_code
    case $style in
        bold) style_code=$bold ;; underline) style_code=$underline ;;
        normal | *) style_code=$normal ;;
    esac
    echo -e "${style_code}${color_code}${text}${reset}"
}
press_key() {
    read -r -p "Press any key to continue..."
}
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input
    echo -ne "[-] $prompt (default: $default): "
    read -r input
    eval "$var_name=\"${input:-$default}\""
}
prompt_boolean() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    while true; do
        prompt_with_default "$prompt [true/false]" "$default" "$var_name"
        local value="${!var_name}"
        if [[ "$value" == "true" || "$value" == "false" ]]; then
            break
        fi
        colorize red "Invalid input. Please enter 'true' or 'false'."
    done
}
validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi
    IFS='/' read -r ip mask <<< "$cidr"
    IFS='.' read -r a b c d <<< "$ip"
    if (( a<0 || a>255 || b<0 || b>255 || c<0 || c>255 || d<0 || d>255 )); then
        return 1
    fi
    if (( mask < 1 || mask > 32 )); then
        return 1
    fi
    local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    local mask_int
    if (( mask == 32 )); then
        mask_int=0xFFFFFFFF
    else
        mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    fi
    local net_int=$(( ip_int & mask_int ))
    local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
    if (( ip_int == net_int )); then
        return 1
    fi
    if (( ip_int == broadcast_int )); then
        return 1
    fi
    return 0
}
install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            colorize yellow "Installing jq..."
            sudo apt-get update && sudo apt-get install -y jq
        else
            colorize red "Error: Unsupported package manager. Please install jq manually."
            press_key
            exit 1
        fi
    fi
}
download_and_extract_leech() {
    if [[ "$1" == "menu" ]]; then
        colorize cyan "Reinstalling / updating the LEECH core..." bold
        rm -f "${config_dir}/leech" >/dev/null 2>&1
    fi
    mkdir -p "$config_dir"
    # 1) Already installed -> use it. We build LEECH ourselves; no download needed.
    if [[ -f "${config_dir}/leech" ]]; then
        chmod u+x "${config_dir}/leech" 2>/dev/null
        return 0
    fi
    # 2) Prefer a binary bundled next to this script (e.g. a cloned LeechTunnel repo).
    local sdir cand
    sdir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" 2>/dev/null && pwd)"
    for cand in "$sdir/leech" "$sdir/leech.bin" "/root/leech.bin" "$PWD/leech"; do
        if [[ -f "$cand" && "$cand" != "${config_dir}/leech" ]]; then
            cp -f "$cand" "${config_dir}/leech"; chmod u+x "${config_dir}/leech"
            colorize green "LEECH core installed from $cand"
            return 0
        fi
    done
    # 3) Download the obfuscated core — always the LATEST published release
    #    (/releases/latest/download redirects to the newest release's asset).
    local URL="https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech"
    echo "Downloading LEECH core (latest release)..."
    if curl -fL --progress-bar --max-time 180 -o "${config_dir}/leech" "$URL" && [[ -s "${config_dir}/leech" ]]; then
        chmod u+x "${config_dir}/leech"
        colorize green "LEECH installation completed."
        return 0
    fi
    rm -f "${config_dir}/leech"
    colorize red "Could not download the LEECH core."
    colorize yellow "Place the binary manually at ${config_dir}/leech and re-run:"
    colorize yellow "    mkdir -p ${config_dir} && cp /path/to/leech ${config_dir}/leech"
    exit 1
}
# Non-interactive flag modes (--gen/--create/--rm/--list/--stats, used by the
# leech-panel) skip the interactive load-time side effects (jq install, binary
# download, ipwhois lookups, backup reconcile) — they add latency and can hang.
if [[ "${1:-}" != --* ]]; then
    install_jq
    download_and_extract_leech
fi
declare -A CONFIG
reset_config() {
    CONFIG=()
}
prompt_connection_section() {
    local mode="$1"  # server or client
    colorize blue "━━━ Connection Configuration ━━━" bold
    if [[ "$mode" == "server" ]]; then
        prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]
        if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
            CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
        fi
    else
        while true; do
            echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
            read -r CONFIG[remote_addr]
            if [[ -z "${CONFIG[remote_addr]}" ]]; then
                colorize red "Server address cannot be empty."
                continue
            fi
            if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
            "${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
                break
            else
                colorize red "Invalid format. Use IP:Port or Domain:Port."
            fi
        done
        if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
            echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
            read -r CONFIG[edge_ip]
        fi
        CONFIG[dial_timeout]="10"
        CONFIG[retry_interval]="3"
    fi
    echo ""
}
VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
is_valid_algorithm() {
    local input="$1"
    for alg in "${VALID_ALGORITHMS[@]}"; do
        if [[ "$input" == "$alg" ]]; then
            return 0
        fi
    done
    return 1
}
prompt_security_section() {
    local is_ipx="$1"
    colorize blue "━━━ Security Configuration ━━━" bold
    if [[ "$is_ipx" == "true" ]]; then
        prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]
        if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
            echo
            while true; do
                colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
                prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]
                if is_valid_algorithm "${CONFIG[algorithm]}"; then
                    break
                else
                    colorize red "Invalid algorithm selected. Please choose one from the list."
                    echo
                fi
            done
            prompt_with_default "PSK (32-char base64)" "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        prompt_with_default "Security Token" "your_token" CONFIG[token]
        CONFIG[enable_encryption]="false"
    fi
    echo ""
}
prompt_transport_section() {
    local mode="$1"
    local is_ipx="false"
    colorize blue "━━━ Transport Configuration ━━━" bold
    local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls kcp tun)
    echo "Available transports:"
    printf '  • %s\n' "${valid_transports[@]}"
    while true; do
        echo -ne "Select transport: "
        read -r CONFIG[transport_type]
        [[ " ${valid_transports[*]} " =~ " ${CONFIG[transport_type]} " ]] && break
        colorize red "Invalid transport."
    done
    if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
        echo
        local encapsulations=(tcp ipx)
        echo "Available encapsulations:"
        printf '  • %s\n' "${encapsulations[@]}"
        while true; do
            echo -ne "Select encapsulation: "
            read -r CONFIG[tun_encapsulation]
            [[ " ${encapsulations[*]} " =~ " ${CONFIG[tun_encapsulation]} " ]] && break
            colorize red "Invalid encapsulation."
        done
    fi
    echo
    if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
        is_ipx="true"
    fi
    if [[ "$is_ipx" != "true" ]]; then
        prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
    fi
    if [[ "$mode" == "server" ]]; then
        if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
            prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
        fi
        if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
            prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
        fi
    else
        if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
            prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
        fi
    fi
    CONFIG[heartbeat_interval]="10"
    CONFIG[heartbeat_timeout]="25"
    if [[ "$is_ipx" != "true" ]]; then
        CONFIG[keepalive_period]="40"
    fi
    # DPI/perf acceleration — ONE master switch, default ON, overridable.
    # ipx is the raw-packet engine (no TCP socket) so acceleration doesn't apply there.
    if [[ "$is_ipx" != "true" ]]; then
        colorize magenta "Acceleration = BBR congestion (DPI-invisible; ~55x faster under packet loss," normal
        colorize magenta "neutral on a clean link) + token obfuscation on raw-TCP carriers. Recommended ON for Iran." normal
        prompt_boolean "Enable acceleration" "true" CONFIG[acceleration]
        if [[ "${CONFIG[acceleration]}" != "false" ]]; then
            # advanced overrides — press Enter to accept the smart defaults
            prompt_with_default "  ↳ Congestion Control [bbr / cubic / empty=kernel]" "bbr" CONFIG[congestion]
            if [[ "${CONFIG[transport_type]}" =~ ^(tcp|tcpmux)$ ]]; then
                colorize yellow "  note: obfuscation trades ~15% clean-link speed for hiding the plaintext token." normal
                prompt_with_default "  ↳ Obfuscation [noise / empty=off]" "noise" CONFIG[obfuscation]
            fi
        else
            CONFIG[congestion]=""
            CONFIG[obfuscation]=""
        fi
    fi
    echo ""
}
prompt_mux_section() {
    local transport="$1"
    if [[ ! "$transport" =~ mux$ ]]; then
        return
    fi
    colorize blue "━━━ Mux Configuration ━━━" bold
    prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
    prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
    CONFIG[mux_framesize]="32768"
    CONFIG[mux_recievebuffer]="4194304"
    CONFIG[mux_streambuffer]="2097152"
    echo ""
}
prompt_tun_section() {
    local transport="$1"
    local mode="$2"
    local is_ipx="$3"
    [[ "$transport" != "tun" ]] && return
    colorize blue "━━━ TUN Configuration ━━━" bold
    prompt_with_default "TUN Device Name" "leech" CONFIG[tun_name]
    local default_local default_remote
    if [[ "$mode" == "server" ]]; then
        default_local="10.10.10.1/24"
        default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"
        default_remote="10.10.10.1/24"
    fi
    while true; do
        prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
        if validate_cidr "${CONFIG[tun_local_addr]}"; then
            break
        fi
        local suggested=$(validate_cidr "${CONFIG[tun_local_addr]}" 2>&1)
        colorize red "Invalid CIDR. Network address should be: $suggested"
    done
    while true; do
        prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
        if validate_cidr "${CONFIG[tun_remote_addr]}"; then
            break
        fi
        colorize red "Invalid CIDR format."
    done
    prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
    else
        prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
    fi
    echo ""
}
prompt_tls_section() {
    local mode="$1"
    local transport="$2"
    if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
        return
    fi
    colorize blue "━━━ TLS Configuration ━━━" bold
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
    fi
    if [[ "$mode" == "client" ]]; then
        echo
        return
    fi
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        colorize red "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out  "$CERT_FILE" -subj "/CN=leech.com"
        colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
        echo
    fi
    prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
    prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
    echo ""
}
prompt_tuning_section() {
    local is_ipx="$1"
    local is_tun="$2"
    colorize blue "━━━ Tuning Configuration ━━━" bold
    prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
    echo
    colorize magenta "Profiles: balanced, fast, latency, resource" normal
    prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
    prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]
    if [[ "$is_tun" != "true" ]]; then
        prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
    fi
    if [[ "$is_tun" == "true" ]]; then
        # a layer-3 device sees far more packets per second than a stream carrier
        CONFIG[channel_size]="10000"
    fi
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    else
        prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
        prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    fi
    if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
        echo
        colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
        prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
        prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
    fi
    echo ""
}
prompt_logging_section() {
    colorize blue "━━━ Logging Configuration ━━━" bold
    colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
    prompt_with_default "Log Level" "info" CONFIG[log_level]
    echo ""
}
prompt_accept_udp_section() {
    local accept_udp="$1"
    [[ "$accept_udp" != "true" ]] && return
    CONFIG[ring_size]="64"
    CONFIG[frame_size]="2048"
    CONFIG[peer_idle_timeout_s]="120"
    CONFIG[write_timeout_ms]="3"
}
prompt_ports_section() {
    local mode="$1"
    local is_tun="$2"
    [[ "$mode" != "server" ]] && return
    if [[ "$is_tun" != "true" ]]; then
        colorize blue "━━━ Port Mapping Configuration ━━━" bold
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo "  3. 443-600       - Listen on range 443-600"
        echo "  4. 443-600:5201  - Range forwarding to 5201"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    else
        colorize blue "━━━ Port Mapping Configuration (tun helper) ━━━" bold
        colorize magenta "Forwarder: use 'leech' for TCP support only, or 'iptables' for TCP + UDP support"
        prompt_with_default "Forwarder (leech/iptables)" "leech" CONFIG[forwarder]
        echo ""
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    fi
}
prompt_ipx_section() {
    local is_ipx="$1"
    local mode="$2"
    [[ "$is_ipx" != "true" ]] && return
    colorize blue "━━━ IPX Configuration ━━━" bold
    CONFIG[ipx_mode]="$mode"
    AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
    colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
    while true; do
        prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]
        CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
        for profile in "${AVAILABLE_PROFILES[@]}"; do
            if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
                break 2
            fi
        done
        colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
        echo
        colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
    done
    prompt_with_default "Listen IP" "$SERVER_IP" CONFIG[ipx_listen_ip]
    while :; do
        prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]
        if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
            break
        fi
        colorize red "Destination IP cannot be empty."
    done
    interface=$(ip route show default | awk '{print $5}')
    prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
        prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
    fi
    echo ""
}
generate_toml_config() {
    local mode="$1"
    local output_file="$2"
    local is_tun="$3"
    local is_ipx="$4"
    {
        if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
            echo "[listener]"
            echo "bind_addr = \"${CONFIG[bind_addr]}\""
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            echo "remote_addr = \"${CONFIG[remote_addr]}\""
            [[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi
        echo "[transport]"
        echo "type = \"${CONFIG[transport_type]}\""
        [[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
        [[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
        if [[ "$mode" == "server" ]]; then
            [[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
            [[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
        else
            [[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] && \
            echo "connection_pool = ${CONFIG[connection_pool]}"
        fi
        [[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
        [[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
        # --- DPI/perf acceleration (reconstruction; original defaults it OFF) ---
        # ONE master switch CONFIG[acceleration], default ON. OFF => faithful plain config.
        local accel="${CONFIG[acceleration]:-true}"
        if [[ "$accel" != "false" ]]; then
            # BBR: DPI-invisible congestion control (~55x faster under loss, neutral on a
            # clean link). Every TCP-family carrier — NOT the raw ipx engine. Empty => skip.
            if [[ "$is_ipx" != "true" ]]; then
                local cc="${CONFIG[congestion]-bbr}"
                [[ -n "$cc" ]] && echo "congestion = \"$cc\""
            fi
            # Noise: hides the plaintext token on the raw-TCP carriers (tcp/tcpmux) only —
            # TLS carriers already hide it. Trades ~15% clean speed for concealment. Empty => skip.
            if [[ "${CONFIG[transport_type]}" =~ ^(tcp|tcpmux)$ ]]; then
                local ob="${CONFIG[obfuscation]-noise}"
                [[ -n "$ob" ]] && echo "obfuscation = \"$ob\""
            fi
        fi
        # --- Phase-2 DPI-hardening molecules (reconstruction; all opt-in, faithful default) ---
        [[ -n "${CONFIG[ws_path_secret]}" ]]    && echo "ws_path_secret = ${CONFIG[ws_path_secret]}"
        [[ -n "${CONFIG[ws_host]}" ]]           && echo "ws_host = \"${CONFIG[ws_host]}\""
        [[ -n "${CONFIG[fake_site_upstream]}" ]] && echo "fake_site_upstream = \"${CONFIG[fake_site_upstream]}\""
        [[ -n "${CONFIG[fake_site_file]}" ]]    && echo "fake_site_file = \"${CONFIG[fake_site_file]}\""
        [[ -n "${CONFIG[obfs_rotate_magic]}" ]] && echo "obfs_rotate_magic = ${CONFIG[obfs_rotate_magic]}"
        [[ -n "${CONFIG[obfs_junk_count]}" ]]   && echo "obfs_junk_count = ${CONFIG[obfs_junk_count]}"
        [[ -n "${CONFIG[obfs_junk_min]}" ]]     && echo "obfs_junk_min = ${CONFIG[obfs_junk_min]}"
        [[ -n "${CONFIG[obfs_junk_max]}" ]]     && echo "obfs_junk_max = ${CONFIG[obfs_junk_max]}"
        [[ -n "${CONFIG[adaptive]}" ]]          && echo "adaptive = ${CONFIG[adaptive]}"
        [[ -n "${CONFIG[adaptive_failures]}" ]] && echo "adaptive_failures = ${CONFIG[adaptive_failures]}"
        [[ -n "${CONFIG[adaptive_carriers]}" ]] && echo "adaptive_carriers = ${CONFIG[adaptive_carriers]}"
        echo ""
        if [[ "$is_tun" == "true" ]]; then
            echo "[tun]"
            echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
            echo "name = \"${CONFIG[tun_name]}\""
            echo "local_addr = \"${CONFIG[tun_local_addr]}\""
            echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            echo ""
        fi
        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            echo "mode = \"${CONFIG[ipx_mode]}\""
            echo "profile = \"${CONFIG[ipx_profile]}\""
            echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
            echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
            echo "interface = \"${CONFIG[ipx_interface]}\""
            [[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
            [[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
            echo "[mux]"
            echo "mux_version = ${CONFIG[mux_version]}"
            echo "mux_framesize = ${CONFIG[mux_framesize]}"
            echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
            echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
            [[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" == "kcp" ]]; then
            echo "[kcp]"
            echo "mode = \"${CONFIG[kcp_mode]:-fast2}\""
            echo "data_shards = ${CONFIG[kcp_data_shards]:-10}"
            echo "parity_shards = ${CONFIG[kcp_parity_shards]:-3}"
            echo "mtu = ${CONFIG[kcp_mtu]:-1350}"
            [[ -n "${CONFIG[kcp_snd_wnd]}" ]] && echo "snd_wnd = ${CONFIG[kcp_snd_wnd]}"
            [[ -n "${CONFIG[kcp_rcv_wnd]}" ]] && echo "rcv_wnd = ${CONFIG[kcp_rcv_wnd]}"
            echo ""
        fi
        echo "[security]"
        if [[ "$is_ipx" == "true" ]]; then
            echo "enable_encryption = ${CONFIG[enable_encryption]}"
            [[ "${CONFIG[enable_encryption]}" == "true" ]] && {
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            }
        else
            echo "token = \"${CONFIG[token]}\""
        fi
        echo ""
        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" || -n "${CONFIG[tls_sni_list]}" ]]; then
            echo "[tls]"
            [[ -n "${CONFIG[tls_sni]}" ]]      && echo "sni = \"${CONFIG[tls_sni]}\""
            [[ -n "${CONFIG[tls_sni_list]}" ]] && echo "sni_list = ${CONFIG[tls_sni_list]}"
            [[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
            [[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = \"${CONFIG[tls_key]}\""
            echo ""
        fi
        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]]  && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
        [[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]]  && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
        [[ -n "${CONFIG[batch_size]}" ]]      && echo "batch_size = ${CONFIG[batch_size]}"
        [[ -n "${CONFIG[read_timeout]}" ]]    && echo "read_timeout = ${CONFIG[read_timeout]}"
        echo ""
        if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
            echo "[accept_udp]"
            echo "ring_size = ${CONFIG[ring_size]}"
            echo "frame_size = ${CONFIG[frame_size]}"
            echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
            echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
            echo ""
        fi
        echo "[logging]"
        echo "log_level = \"${CONFIG[log_level]}\""
        echo ""
        if [[ "$mode" == "server" ]] ; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]]  && echo "forwarder = \"${CONFIG[forwarder]}\""
            echo "mapping = ["
            IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
            for port in "${ports[@]}"; do
                [[ -n "$port" ]] && echo "    \"${port// /}\","
            done
            echo "]"
        fi
    } > "$output_file"
}
# csv_to_toml_array "a, b ,c" -> ["a","b","c"]
csv_to_toml_array() {
    local IFS=',' item out=""
    for item in $1; do
        item="${item// /}"; [[ -z "$item" ]] && continue
        out="$out\"$item\","
    done
    echo "[${out%,}]"
}
prompt_kcp_section() {
    [[ "$1" != "kcp" ]] && return
    colorize blue "━━━ KCP+FEC Configuration ━━━" bold
    colorize magenta "KCP over UDP with Reed-Solomon FEC — reads as QUIC on UDP/443; FEC recovers loss without a retransmit RTT." normal
    prompt_with_default "KCP mode [normal/fast/fast2/fast3]" "fast2" CONFIG[kcp_mode]
    prompt_with_default "FEC data shards" "10" CONFIG[kcp_data_shards]
    prompt_with_default "FEC parity shards (0 = FEC off)" "3" CONFIG[kcp_parity_shards]
    prompt_with_default "MTU" "1350" CONFIG[kcp_mtu]
    echo ""
}
prompt_dpi_section() {
    local mode="$1" transport="$2"
    colorize blue "━━━ DPI Hardening (Phase-2, opt-in) ━━━" bold
    if [[ "$transport" =~ ^(ws|wss|wsmux|wssmux)$ ]]; then
        prompt_boolean "Secret WS path (hide /channel,/tunnel via HMAC(token)) [set on BOTH ends]" "true" CONFIG[ws_path_secret]
        prompt_with_default "  ↳ Fronting Host header (empty = use SNI under acceleration)" "" CONFIG[ws_host]
        [[ "$mode" == "server" ]] && prompt_with_default "  ↳ Fake-site reverse-proxy upstream (empty = built-in decoy page)" "" CONFIG[fake_site_upstream]
    fi
    if [[ "$transport" == "xtcpmux" ]]; then
        prompt_boolean "Rotate xtcpmux obfs magic per-deployment (from token) [BOTH ends]" "true" CONFIG[obfs_rotate_magic]
    fi
    if [[ "$transport" =~ ^(tcp|tcpmux)$ || "$transport" == "tun" ]]; then
        prompt_with_default "AmneziaWG junk packets before Noise handshake (0 = off) [BOTH ends]" "0" CONFIG[obfs_junk_count]
        if [[ -n "${CONFIG[obfs_junk_count]}" && "${CONFIG[obfs_junk_count]}" != "0" ]]; then
            CONFIG[obfs_junk_min]="40"; CONFIG[obfs_junk_max]="1000"
        fi
    fi
    if [[ "$transport" =~ ^(wss|wssmux|anytls)$ ]]; then
        prompt_with_default "SNI rotation list (comma-separated; empty = single SNI)" "" CONFIG[dpi_sni_list_raw]
        [[ -n "${CONFIG[dpi_sni_list_raw]}" ]] && CONFIG[tls_sni_list]="$(csv_to_toml_array "${CONFIG[dpi_sni_list_raw]}")"
    fi
    if [[ "$mode" == "client" ]]; then
        prompt_boolean "Adaptive failover (auto-switch carrier when one is blocked)" "false" CONFIG[adaptive]
        if [[ "${CONFIG[adaptive]}" == "true" ]]; then
            prompt_with_default "  ↳ Carriers (comma-sep 'type@host:port')" "" CONFIG[dpi_adaptive_raw]
            CONFIG[adaptive_carriers]="$(csv_to_toml_array "${CONFIG[dpi_adaptive_raw]}")"
            prompt_with_default "  ↳ Consecutive failures before switching" "3" CONFIG[adaptive_failures]
        fi
    fi
    echo ""
}
# Non-interactive config generation for scripted / multi-transport deploys:
#   leech.sh --gen <server|client> <output.toml>
# reads BH_* env vars into CONFIG then writes the TOML (no prompts).
gen_noninteractive() {
    local mode="$1" out="$2"
    declare -gA CONFIG=()
    CONFIG[transport_type]="${BH_TYPE:-tcp}"
    CONFIG[bind_addr]="${BH_BIND}"
    CONFIG[remote_addr]="${BH_REMOTE}"
    CONFIG[edge_ip]="${BH_EDGE_IP}"
    CONFIG[dial_timeout]="${BH_DIAL_TIMEOUT:-10}"
    CONFIG[retry_interval]="${BH_RETRY:-3}"
    # No silent fallback: an empty token would install the well-known default on
    # both ends, which is an open door — fail loudly instead. The ipx raw engine
    # has no token handshake at all (it authenticates with the PSK), so it is exempt.
    if [[ "${BH_TUN_ENCAP}" == "ipx" ]]; then
        CONFIG[token]="${BH_TOKEN}"
    else
        CONFIG[token]="${BH_TOKEN:?BH_TOKEN is required}"
    fi
    CONFIG[nodelay]="${BH_NODELAY:-true}"
    CONFIG[keepalive_period]="${BH_KEEPALIVE:-40}"
    # a layer-3 device has no pool of tunnel connections to pre-open
    if [[ "${BH_TYPE:-tcp}" == "tun" ]]; then CONFIG[connection_pool]="${BH_POOL}"; else CONFIG[connection_pool]="${BH_POOL:-8}"; fi
    CONFIG[heartbeat_interval]="${BH_HB_INT:-10}"
    CONFIG[heartbeat_timeout]="${BH_HB_TO:-25}"
    CONFIG[acceleration]="${BH_ACCEL:-true}"
    CONFIG[congestion]="${BH_CONGESTION-bbr}"
    CONFIG[obfuscation]="${BH_OBFS-}"
    CONFIG[mux_version]="${BH_MUX_VERSION:-2}"
    CONFIG[mux_framesize]="${BH_MUX_FRAME:-32768}"; CONFIG[mux_recievebuffer]="${BH_MUX_RCVBUF:-4194304}"
    CONFIG[mux_streambuffer]="${BH_MUX_STREAMBUF:-2097152}"; CONFIG[mux_concurrency]="${BH_MUX_CONC:-8}"
    # anytls is the one transport the interactive path asks an SNI for (and so always
    # writes); the others take the core's own default unless one is given
    if [[ "${BH_TYPE}" == "anytls" ]]; then CONFIG[tls_sni]="${BH_SNI:-www.digikala.com}"; else CONFIG[tls_sni]="${BH_SNI}"; fi
    CONFIG[tls_sni_list]="${BH_SNI_LIST:+$(csv_to_toml_array "$BH_SNI_LIST")}"
    # A server with no cert on disk falls back to an in-memory self-signed one that
    # is regenerated on every restart, i.e. a fingerprint that changes each bounce.
    # Mint the same stable pair the interactive path does instead.
    if [[ "$mode" == "server" && "${BH_TYPE}" =~ ^(wss|wssmux|anytls)$ ]]; then
        if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
            mkdir -p "$(dirname "$CERT_FILE")"
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 \
                -days 365 -sha256 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=leech.com" >/dev/null 2>&1
        fi
        CONFIG[tls_cert]="${BH_TLS_CERT:-$CERT_FILE}"; CONFIG[tls_key]="${BH_TLS_KEY:-$KEY_FILE}"
    else
        CONFIG[tls_cert]="${BH_TLS_CERT}"; CONFIG[tls_key]="${BH_TLS_KEY}"
    fi
    CONFIG[ws_path_secret]="${BH_WS_PATH_SECRET}"; CONFIG[ws_host]="${BH_WS_HOST}"
    CONFIG[fake_site_upstream]="${BH_FAKE_UPSTREAM}"; CONFIG[fake_site_file]="${BH_FAKE_FILE}"
    CONFIG[obfs_rotate_magic]="${BH_OBFS_ROTATE}"
    # junk is prompted (and so written, even as 0) on the Noise-capable carriers
    CONFIG[obfs_junk_count]="${BH_JUNK_COUNT}"
    [[ "${BH_TYPE:-tcp}" =~ ^(tcp|tcpmux|tun)$ ]] && CONFIG[obfs_junk_count]="${BH_JUNK_COUNT:-0}"
    CONFIG[obfs_junk_min]="${BH_JUNK_MIN}"; CONFIG[obfs_junk_max]="${BH_JUNK_MAX}"
    # the interactive path hardcodes junk min/max = 40/1000 whenever junk is ON (line ~661);
    # mirror it so a panel tunnel with junk>0 carries the same range instead of omitting it.
    if [[ -n "${CONFIG[obfs_junk_count]}" && "${CONFIG[obfs_junk_count]}" != "0" ]]; then
        CONFIG[obfs_junk_min]="${BH_JUNK_MIN:-40}"; CONFIG[obfs_junk_max]="${BH_JUNK_MAX:-1000}"
    fi
    # adaptive is a client-side prompt, written even when off
    CONFIG[adaptive]="${BH_ADAPTIVE}"
    [[ "$mode" == "client" ]] && CONFIG[adaptive]="${BH_ADAPTIVE:-false}"
    CONFIG[adaptive_failures]="${BH_ADAPTIVE_FAILURES}"; CONFIG[adaptive_carriers]="${BH_ADAPTIVE_CARRIERS:+$(csv_to_toml_array "$BH_ADAPTIVE_CARRIERS")}"
    CONFIG[kcp_mode]="${BH_KCP_MODE:-fast2}"; CONFIG[kcp_data_shards]="${BH_KCP_DATA:-10}"
    CONFIG[kcp_parity_shards]="${BH_KCP_PARITY:-3}"; CONFIG[kcp_mtu]="${BH_KCP_MTU:-1350}"
    CONFIG[tun_encapsulation]="${BH_TUN_ENCAP}"; CONFIG[tun_name]="${BH_TUN_NAME:-leech}"
    CONFIG[tun_local_addr]="${BH_TUN_LOCAL:-10.10.10.1/24}"; CONFIG[tun_remote_addr]="${BH_TUN_REMOTE:-10.10.10.2/24}"
    CONFIG[tun_health_port]="${BH_TUN_HEALTH:-1234}"
    # the raw engine adds outer headers, so it needs the smaller MTU the
    # interactive path offers (1320 vs 1500) — the panel has one field for both
    local _def_mtu=1500; [[ "${BH_TUN_ENCAP}" == "ipx" ]] && _def_mtu=1320
    CONFIG[tun_mtu]="${BH_TUN_MTU:-$_def_mtu}"
    CONFIG[ipx_mode]="${BH_IPX_MODE}"; CONFIG[ipx_profile]="${BH_IPX_PROFILE:-tcp}"
    CONFIG[ipx_listen_ip]="${BH_IPX_LISTEN}"; CONFIG[ipx_dst_ip]="${BH_IPX_DST}"
    # the NIC name is per-box, so it must be resolved here and not by the panel
    CONFIG[ipx_interface]="${BH_IPX_IFACE:-$(ip route show default 2>/dev/null | awk '{print $5; exit}')}"
    CONFIG[auto_tuning]="${BH_AUTO_TUNING:-true}"; CONFIG[tuning_profile]="${BH_TUNING_PROFILE:-balanced}"
    CONFIG[workers]="${BH_WORKERS:-0}"
    # a layer-3 device sees far more packets per second than a stream carrier, so
    # the interactive path gives tun a much deeper channel
    local _def_chan=4096; [[ "${BH_TYPE}" == "tun" ]] && _def_chan=10000
    CONFIG[channel_size]="${BH_CHANNEL:-$_def_chan}"
    CONFIG[batch_size]="${BH_BATCH}"; CONFIG[read_timeout]="${BH_READ_TIMEOUT}"
    CONFIG[log_level]="${BH_LOG:-info}"
    # the forwarder choice is a tun-only helper (the interactive path only asks for
    # it there); on a stream transport the core's own default applies
    if [[ "${BH_TYPE}" == "tun" ]]; then CONFIG[forwarder]="${BH_FORWARDER:-leech}"; else CONFIG[forwarder]="${BH_FORWARDER}"; fi
    CONFIG[ports_mapping]="${BH_PORTS}"; CONFIG[enable_encryption]="${BH_ENC:-false}"
    # The interactive path answers these prompts (and therefore writes them, even at
    # their zero value) under exactly the conditions below. Mirror the same gates, or
    # the two entry points produce configs that differ only on paper — or, worse,
    # carry a key on a transport the interactive path never writes it for.
    CONFIG[accept_udp]="${BH_ACCEPT_UDP}"
    [[ "$mode" == "server" && "${BH_TYPE:-tcp}" == "tcp" ]] && CONFIG[accept_udp]="${BH_ACCEPT_UDP:-false}"
    CONFIG[proxy_protocol]="${BH_PROXY_PROTO}"
    [[ "$mode" == "server" && ! "${BH_TYPE:-tcp}" =~ ^(tun|ws)$ && "${BH_TUN_ENCAP}" != "ipx" ]] && CONFIG[proxy_protocol]="${BH_PROXY_PROTO:-false}"
    if [[ "${BH_TUN_ENCAP}" == "ipx" ]]; then
        CONFIG[tcp_mss]="${BH_TCP_MSS}"; CONFIG[so_rcvbuf]="${BH_SO_RCVBUF}"
        CONFIG[so_sndbuf]="${BH_SO_SNDBUF:-0}"; CONFIG[buffer_profile]="${BH_BUFFER_PROFILE}"
    else
        CONFIG[tcp_mss]="${BH_TCP_MSS:-0}"; CONFIG[so_rcvbuf]="${BH_SO_RCVBUF:-0}"
        CONFIG[so_sndbuf]="${BH_SO_SNDBUF:-0}"
        # buffer_profile + read_timeout are stream-only prompts
        if [[ "${BH_TYPE:-tcp}" == "tun" ]]; then CONFIG[buffer_profile]="${BH_BUFFER_PROFILE}"
        else CONFIG[buffer_profile]="${BH_BUFFER_PROFILE:-balanced}"; fi
    fi
    CONFIG[kcp_snd_wnd]="${BH_KCP_SND_WND}"; CONFIG[kcp_rcv_wnd]="${BH_KCP_RCV_WND}"
    # icmp type/code are prompted (default 0) ONLY for the icmp profile — mirror that gate
    # so the generated TOML matches the interactive path (icmp_type=0/icmp_code=0), and
    # they are never written for other profiles.
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        CONFIG[ipx_icmp_type]="${BH_IPX_ICMP_TYPE:-0}"; CONFIG[ipx_icmp_code]="${BH_IPX_ICMP_CODE:-0}"
    else
        CONFIG[ipx_icmp_type]="${BH_IPX_ICMP_TYPE}"; CONFIG[ipx_icmp_code]="${BH_IPX_ICMP_CODE}"
    fi
    # these are written UNCONDITIONALLY inside their blocks when enabled, so default
    # them (empty would emit invalid TOML like 'kdf_iterations = ')
    CONFIG[algorithm]="${BH_ALGORITHM:-aes-256-gcm}"; CONFIG[kdf_iterations]="${BH_KDF_ITER:-100000}"
    # an empty PSK with encryption on is a config that looks encrypted and is not
    if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
        CONFIG[psk]="${BH_PSK:?BH_PSK is required when encryption is enabled}"
    else
        CONFIG[psk]="${BH_PSK}"
    fi
    CONFIG[ring_size]="${BH_RING_SIZE:-64}"; CONFIG[frame_size]="${BH_FRAME_SIZE:-2048}"
    CONFIG[peer_idle_timeout_s]="${BH_PEER_IDLE:-120}"; CONFIG[write_timeout_ms]="${BH_WRITE_TIMEOUT:-3}"
    local is_tun=false is_ipx=false
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun=true
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx=true
    # The ipx raw-packet engine has no TCP socket, so the interactive path never
    # asks for (and never emits) these. Blank them here too, or a panel-created ipx
    # tunnel would carry socket knobs the configurator's own output does not have.
    if [[ "$is_ipx" == "true" ]]; then
        CONFIG[nodelay]=""; CONFIG[keepalive_period]=""
        CONFIG[dial_timeout]=""; CONFIG[retry_interval]=""
        CONFIG[connection_pool]=""; CONFIG[congestion]=""; CONFIG[obfuscation]=""
    fi
    generate_toml_config "$mode" "$out" "$is_tun" "$is_ipx"
    echo "generated $out (type=${CONFIG[transport_type]} mode=$mode)"
}
configure_server() {
    local mode="$1"  # server or client
    local mode_name
    if [[ "$mode" == "server" ]]; then
        mode_name="IRAN (Server)"
    else
        mode_name="KHAREJ (Client)"
    fi
    clear
    colorize cyan "Configuring $mode_name" bold
    echo ""
    reset_config
    prompt_transport_section "$mode"
    local is_tun="false"
    local is_ipx="false"
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
    prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
    prompt_ipx_section "$is_ipx" "$mode"
    if [[ "$is_ipx" != "true" ]]; then
        prompt_connection_section "$mode"
    fi
    prompt_security_section "$is_ipx"
    prompt_accept_udp_section "${CONFIG[accept_udp]}"
    prompt_mux_section "${CONFIG[transport_type]}"
    prompt_tls_section "$mode" "${CONFIG[transport_type]}"
    prompt_kcp_section "${CONFIG[transport_type]}"
    prompt_dpi_section "$mode" "${CONFIG[transport_type]}"
    prompt_tuning_section "$is_ipx" "$is_tun"
    prompt_logging_section
    prompt_ports_section "$mode" "$is_tun"
    local tunnel_port
    if [[ "$mode" == "server" ]]; then
        tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
    else
        tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
    fi
    if [[ -z "$tunnel_port" ]]; then
        tunnel_port=$(echo "${CONFIG[tun_health_port]}")
    fi
    local config_file
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"
    fi
    generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
    local service_type
    [[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file"
    echo ""
    colorize green "✔ Configuration completed successfully!" bold
    echo ""
    press_key
}
create_systemd_service() {
    local type="$1"
    local port="$2"
    local config_file="$3"
    local service_file="${service_dir}/leech-${type}${port}.service"
    local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
    cat > "$service_file" <<EOF
[Unit]
Description=LEECH $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/leech -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "leech-${type}${port}.service" >/dev/null 2>&1
    colorize green "✔ Service leech-${type}${port} created and started" bold
}
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ "${1:-}" != --* ]]; then
    SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country')
    SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp')
fi
display_logo() {
    echo -e "\033[36m"
    cat << "EOF"
██╗     ███████╗███████╗ ██████╗██╗  ██╗
██║     ██╔════╝██╔════╝██╔════╝██║  ██║
██║     █████╗  █████╗  ██║     ███████║
██║     ██╔══╝  ██╔══╝  ██║     ██╔══██║
███████╗███████╗███████╗╚██████╗██║  ██║
╚══════╝╚══════╝╚══════╝ ╚═════╝╚═╝  ╚═╝
Lightning-fast reverse tunneling solution
EOF
    echo -e "\033[0m\033[32m"
    echo -e "Script Version: \033[33m${SCRIPT_VERSION}\033[32m"
    [[ -f "${config_dir}/leech" ]] && \
    echo -e "Core Version: \033[33m$($config_dir/leech -v)\033[32m"
}
display_server_info() {
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
    echo -e "\033[36mIP Address:\033[0m $SERVER_IP"
    echo -e "\033[36mLocation:\033[0m $SERVER_COUNTRY"
    echo -e "\033[36mDatacenter:\033[0m $SERVER_ISP"
}
display_leech_core_status() {
    if [[ -f "${config_dir}/leech" ]]; then
        echo -e "\033[36mLEECH Core:\033[0m \033[32mInstalled\033[0m"
    else
        echo -e "\033[36mLEECH Core:\033[0m \033[31mNot installed\033[0m"
    fi
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
}
check_config_backup() {
    missing_services=()
    for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
        [ -e "$config" ] || continue
        fname=$(basename "$config")
        if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            location="${BASH_REMATCH[1]}"
            tunnel_port="${BASH_REMATCH[2]}"
            service_file="${service_dir}/leech-${location}${tunnel_port}.service"
            if [[ ! -f "$service_file" ]]; then
                missing_services+=("$service_file:$location:$tunnel_port")
            fi
        fi
    done
    [[ ${#missing_services[@]} -eq 0 ]] && return 0
    echo
    colorize red "Missing service files:" bold
    for entry in "${missing_services[@]}"; do
        service_file="${entry%%:*}"
        location="${entry#*:}"; location="${location%%:*}"
        tunnel_port="${entry##*:}"
        echo "- $service_file (type: $location, port: $tunnel_port)"
    done
    echo
    read -r -p "Do you want to create missing service files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for entry in "${missing_services[@]}"; do
            service_file="${entry%%:*}"
            location="${entry#*:}"; location="${location%%:*}"
            tunnel_port="${entry##*:}"
            config_file="${config_dir}/${location}${tunnel_port}.toml"
            desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"
            cat > "$service_file" <<EOF
[Unit]
Description=LEECH $desc_loc Port $tunnel_port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/leech -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now "$(basename "$service_file")"
            echo "Created and started $(basename "$service_file")"
        done
    fi
    sleep 2
}
[[ "${1:-}" != --* ]] && check_config_backup
check_tunnel_status() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize yellow "Checking all services status..." bold
    sleep 1
    echo
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        config_name="${config_name%.toml}"
        service_name="leech-${config_name}.service"
        if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Iran service (port $port) is running"
            else
                colorize red "Iran service (port $port) is not running"
            fi
        elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Kharej service (port $port) is running"
            else
                colorize red "Kharej service (port $port) is not running"
            fi
        fi
    done
    echo
    press_key
}
tunnel_management() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize cyan "Existing services:" bold
    echo
    local index=1
    declare -a configs
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mKharej\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        fi
    done
    echo
    echo -ne "Enter your choice (0 to return): "
    read -r choice
    [[ "$choice" == "0" ]] && return
    while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
        colorize red "Invalid choice."
        echo -ne "Enter your choice (0 to return): "
        read -r choice
        [[ "$choice" == "0" ]] && return
    done
    selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    service_name="leech-${config_name}.service"
    clear
    colorize cyan "Manage $config_name:" bold
    echo
    colorize red "1) Remove this tunnel"
    colorize yellow "2) Restart this tunnel"
    echo "3) View service logs"
    echo "4) View service status"
    echo
    read -r -p "Enter your choice (0 to return): " choice
    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        0) return ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
destroy_tunnel() {
    config_path="$1"
    config_name=$(basename "${config_path%.toml}")
    service_name="leech-${config_name}.service"
    service_path="$service_dir/$service_name"
    [ -f "$config_path" ] && rm -f "$config_path"
    if [[ -f "$service_path" ]]; then
        systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
        rm -f "$service_path"
    fi
    systemctl daemon-reload
    echo
    colorize green "Tunnel destroyed successfully!" bold
    echo
    press_key
}
restart_service() {
    echo
    colorize yellow "Restarting $1" bold
    if systemctl list-units --type=service | grep -q "$1"; then
        systemctl restart "$1"
        colorize green "Service restarted successfully" bold
        echo
    else
        colorize red "Service not found"
    fi
    press_key
}
view_service_logs() {
    clear
    journalctl -eu "$1" -f -o cat
}
view_service_status() {
    clear
    systemctl status "$1"
    press_key
}
remove_core() {
    if find "$config_dir" -type f -name "*.toml" | grep -q .; then
        colorize red "Delete all services first."
        sleep 3
        return 1
    fi
    colorize yellow "Remove LEECH-Core? (y/n)"
    read -r confirm
    if [[ $confirm == [yY] ]]; then
        [[ -d "$config_dir" ]] && rm -rf "$config_dir"
        colorize green "LEECH-Core removed." bold
    fi
    press_key
}
update_script() {
    return
    DEST_DIR="/usr/bin/"
    LEECH_SCRIPT="leech"
    SCRIPT_URL="http://ir.leech-dev.com:2095/leech.sh"
    [ -f "$DEST_DIR/$LEECH_SCRIPT" ] && rm "$DEST_DIR/$LEECH_SCRIPT"
    if curl -s -L -o "$DEST_DIR/$LEECH_SCRIPT" "$SCRIPT_URL"; then
        chmod +x "$DEST_DIR/$LEECH_SCRIPT"
        colorize yellow "Type 'leech' to run the script." bold
        exit 0
    else
        colorize red "Download failed."
    fi
    press_key
}
configure_tunnel() {
    [[ ! -d "$config_dir" ]] && {
        colorize red "Install LEECH-Core first."
        press_key
        return 1
    }
    clear
    echo ""
    colorize green "1) Configure IRAN (Server)" bold
    colorize magenta "2) Configure KHAREJ (Client)" bold
    echo ""
    read -r -p "Enter your choice: " configure_choice
    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
# ===== Web panel (GUI) =====
PANEL_BIN_URL="https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/leech-panel"

install_panel() {
    clear; colorize cyan "Install the LEECH web panel (this server becomes the control hub)" bold; echo
    local port pw pw2
    prompt_with_default "Panel port" "8443" port
    [[ "$port" =~ ^[0-9]+$ ]] || { colorize red "invalid port"; press_key; return; }
    read -rsp "Set an admin password: " pw; echo
    read -rsp "Confirm password: " pw2; echo
    [ "$pw" != "$pw2" ] && { colorize red "passwords do not match"; press_key; return; }
    [ ${#pw} -lt 6 ] && { colorize red "password too short (min 6)"; press_key; return; }
    mkdir -p /etc/leech-panel "$config_dir"
    if [ ! -f "$config_dir/leech-panel" ]; then
        colorize yellow "Downloading panel binary…"
        curl -fL --progress-bar -o "$config_dir/leech-panel" "$PANEL_BIN_URL" || {
            colorize red "download failed — place the binary at $config_dir/leech-panel and re-run"; press_key; return; }
    fi
    chmod +x "$config_dir/leech-panel"
    [ -f /etc/leech-panel/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /etc/leech-panel/id_ed25519 -q
    local sha tok myip hn
    sha=$(printf '%s' "$pw" | sha256sum | awk '{print $1}')
    tok=$(openssl rand -hex 24)
    myip=$(hostname -I | awk '{print $1}'); hn=$(hostname)
    cat > /etc/leech-panel/config.json <<EOF
{
  "port": $port,
  "admin_password_sha256": "$sha",
  "api_token": "$tok",
  "ssh_key_path": "/etc/leech-panel/id_ed25519",
  "nodes": [{"id":"local","name":"$hn","role":"both","host":"$myip","ssh_user":"root","ssh_port":22,"local":true}],
  "tunnels": []
}
EOF
    chmod 600 /etc/leech-panel/config.json
    cat > /etc/systemd/system/leech-panel.service <<EOF
[Unit]
Description=LEECH Web Panel
After=network.target
[Service]
Type=simple
ExecStart=$config_dir/leech-panel --config /etc/leech-panel/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now leech-panel >/dev/null 2>&1
    echo
    if systemctl is-active --quiet leech-panel; then
        colorize green "✔ Panel is running:  http://${myip}:${port}" bold
    else
        colorize red "panel failed to start — check: journalctl -u leech-panel -n 30"
    fi
    echo
    colorize yellow "Panel SSH public key (run 'connect to panel' on each node and paste this):"
    cat /etc/leech-panel/id_ed25519.pub
    press_key
}

connect_to_panel() {
    clear; colorize cyan "Connect this server to a LEECH panel (enroll as a node)" bold; echo
    colorize yellow "Paste the panel's SSH public key (from the panel-install output), then Enter:"
    local pubkey; read -r pubkey
    if [ -n "$pubkey" ]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
        grep -qF "$pubkey" /root/.ssh/authorized_keys || echo "$pubkey" >> /root/.ssh/authorized_keys
        colorize green "✔ Panel key authorized — the panel can now control this node over SSH."
    fi
    echo
    local url pw role name myip tok
    prompt_with_default "Auto-register: panel URL (http://IP:PORT, empty to skip)" "" url
    if [ -n "$url" ]; then
        read -rsp "Panel admin password: " pw; echo
        prompt_with_default "This node's role (iran/kharej/both)" "kharej" role
        name=$(hostname); myip=$(hostname -I | awk '{print $1}')
        tok=$(curl -s --max-time 8 -X POST -H 'Content-Type: application/json' -d "{\"password\":\"$pw\"}" "$url/api/login" | grep -oP '"token":"\K[^"]+')
        if [ -n "$tok" ]; then
            if curl -s --max-time 8 -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
                 -d "{\"name\":\"$name\",\"role\":\"$role\",\"host\":\"$myip\",\"ssh_user\":\"root\",\"ssh_port\":22}" "$url/api/nodes" | grep -q '"ok":true'; then
                colorize green "✔ Registered with the panel as '$name' ($role @ $myip)"
            else
                colorize yellow "node may already exist, or registration failed — you can add it manually in the panel UI ($myip)"
            fi
        else
            colorize red "could not log in to the panel (check URL / password)"
        fi
    fi
    [ -f "$config_dir/leech" ] || colorize yellow "Reminder: this node needs the LEECH core at $config_dir/leech for tunnels to run."
    press_key
}

# Replace the panel binary in place. The running binary's file is busy, so the new
# one lands under a temp name and is swapped while the service is stopped; the old
# build is kept as .bak so a bad download can be rolled back.
update_panel() {
    if [ ! -f "$config_dir/leech-panel" ]; then
        colorize red "panel is not installed here"; press_key; return
    fi
    colorize cyan "downloading the latest panel build…"
    if ! curl -fL --progress-bar -o "$config_dir/leech-panel.new" "$PANEL_BIN_URL"; then
        colorize red "download failed — nothing was changed"; rm -f "$config_dir/leech-panel.new"; press_key; return
    fi
    chmod +x "$config_dir/leech-panel.new"
    if ! "$config_dir/leech-panel.new" --help >/dev/null 2>&1; then
        colorize red "the downloaded file is not a working panel binary — nothing was changed"
        rm -f "$config_dir/leech-panel.new"; press_key; return
    fi
    systemctl stop leech-panel 2>/dev/null
    cp -f "$config_dir/leech-panel" "$config_dir/leech-panel.bak" 2>/dev/null
    mv -f "$config_dir/leech-panel.new" "$config_dir/leech-panel"
    chmod +x "$config_dir/leech-panel"
    systemctl start leech-panel 2>/dev/null
    sleep 1.5
    if systemctl is-active --quiet leech-panel; then
        colorize green "panel updated and running (previous build kept at leech-panel.bak)"
    else
        colorize red "the new build failed to start — rolling back"
        mv -f "$config_dir/leech-panel.bak" "$config_dir/leech-panel" 2>/dev/null
        systemctl start leech-panel 2>/dev/null
        journalctl -u leech-panel -n 15 --no-pager 2>/dev/null
    fi
    press_key
}
configure_panel() {
    while true; do
        clear; display_logo; echo
        colorize cyan " Web Panel (GUI)" bold; echo
        local st; systemctl is-active --quiet leech-panel 2>/dev/null && st="\033[32mrunning\033[0m" || st="\033[31mnot installed\033[0m"
        echo -e " Status: $st"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        colorize green " 1. Install panel (become the control hub)" bold
        colorize magenta " 2. Connect this server to a panel (enroll node)" bold
        echo " 3. Panel status / logs"
        echo " 4. Update panel to the latest build"
        echo " 5. Remove panel"
        echo " 0. Back"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local ch; read -r -p "Choice [0-5]: " ch
        case $ch in
            1) install_panel ;;
            2) connect_to_panel ;;
            3) systemctl status leech-panel --no-pager 2>&1 | head -12; echo; journalctl -u leech-panel -n 15 --no-pager 2>/dev/null; press_key ;;
            4) update_panel ;;
            5) systemctl disable --now leech-panel 2>/dev/null; rm -f /etc/systemd/system/leech-panel.service; systemctl daemon-reload 2>/dev/null; colorize green "panel removed"; press_key ;;
            0) return ;;
            *) colorize red "invalid"; sleep 1 ;;
        esac
    done
}

display_menu() {
    clear
    display_logo
    display_server_info
    display_leech_core_status
    echo
    colorize green " 1. Configure a new tunnel" bold
    colorize red " 2. Tunnel management" bold
    colorize cyan " 3. Check tunnel status" bold
    colorize magenta " 4. Web panel (GUI)" bold
    echo " 5. Update LEECH Core"
    echo " 6. Update script"
    echo " 7. Remove LEECH Core"
    echo " 0. Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
read_option() {
    read -r -p "Enter your choice [0-7]: " choice
    case $choice in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) configure_panel ;;
        5) download_and_extract_leech "menu" ;;
        6) update_script ;;
        7) remove_core ;;
        0) exit 0 ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
# Non-interactive entrypoint for scripted deploys / multi-transport testing.
if [[ "${1:-}" == "--gen" ]]; then
    gen_noninteractive "${2:?usage: --gen <server|client> <out.toml>}" "${3:?usage: --gen <server|client> <out.toml>}"
    exit $?
fi

# ===== non-interactive panel API (driven by leech-panel over SSH/local exec) =====
# JSON in, JSON out. All input comes from BH_* env (already validated by the panel)
# or a strict <type><port> id; nothing is interpolated from free-form user text.

# --create <server|client> : BH_* env -> TOML -> systemd unit -> start.  emits JSON
panel_create() {
    # NOTE: gen_noninteractive/generate_toml_config assign to a non-local `port`,
    # which would clobber a `local port` here via bash dynamic scoping — so use
    # uniquely-named locals captured BEFORE calling gen.
    local mode="$1" pc_typ pc_port pc_out pc_svc pc_act
    if [[ "$mode" == "server" ]]; then pc_typ=iran;   pc_port="${BH_BIND##*:}"
    else                               pc_typ=kharej; pc_port="${BH_REMOTE##*:}"; fi
    [[ "$pc_port" =~ ^[0-9]+$ ]] || { echo '{"ok":false,"error":"could not derive port from BH_BIND/BH_REMOTE"}'; return 1; }
    pc_out="${config_dir}/${pc_typ}${pc_port}.toml"
    pc_svc="leech-${pc_typ}${pc_port}"
    if ! gen_noninteractive "$mode" "$pc_out" >/dev/null 2>&1; then
        echo '{"ok":false,"error":"config generation failed"}'; return 1
    fi
    create_systemd_service "$pc_typ" "$pc_port" "$pc_out" >/dev/null 2>&1
    systemctl is-active --quiet "$pc_svc" && pc_act=true || pc_act=false
    echo "{\"ok\":true,\"type\":\"${pc_typ}\",\"port\":${pc_port},\"service\":\"${pc_svc}\",\"active\":${pc_act}}"
}

# --rm <type><port> : stop+remove one tunnel endpoint.  emits JSON
panel_rm() {
    local id="$1"
    [[ "$id" =~ ^(iran|kharej)[0-9]+$ ]] || { echo '{"ok":false,"error":"bad id"}'; return 1; }
    systemctl disable --now "leech-${id}.service" >/dev/null 2>&1
    rm -f "${service_dir}/leech-${id}.service" "${config_dir}/${id}.toml"
    systemctl daemon-reload 2>/dev/null
    echo "{\"ok\":true,\"removed\":\"${id}\"}"
}

# --list : enumerate local tunnel endpoints.  emits {"tunnels":[...]}
panel_list() {
    local first=1 f name typ port active transport token remote
    printf '{"tunnels":['
    for f in "${config_dir}"/{iran,kharej}*.toml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .toml)
        [[ "$name" =~ ^(iran|kharej)([0-9]+)$ ]] || continue
        typ="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
        # transport + (client's) remote let the panel auto-discover tunnels across nodes
        local transport remote
        transport=$(awk -F'"' '/^type = /{print $2; exit}' "$f" 2>/dev/null)
        remote=""; [[ "$typ" == kharej ]] && remote=$(awk -F'"' '/^remote_addr = /{print $2; exit}' "$f" 2>/dev/null)
        systemctl is-active --quiet "leech-${name}" && active=true || active=false
        transport=$(grep -oP 'type\s*=\s*"\K[^"]+' "$f" | head -1)
        token=$(grep -oP 'token\s*=\s*"\K[^"]+' "$f" | head -1)
        remote=$(grep -oP 'remote_addr\s*=\s*"\K[^"]+' "$f" | head -1)
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"type":"%s","port":%s,"active":%s,"transport":"%s","token":"%s","remote":"%s"}' \
            "$typ" "$port" "$active" "${transport:-}" "${token:-}" "${remote:-}"
    done
    printf ']}\n'
}

# --stats : host + per-tunnel cumulative counters (panel computes rates).
panel_stats() {
    local ncpu cput cpui memt mema memu upt hrx htx
    ncpu=$(nproc 2>/dev/null || echo 1)
    read -r cput cpui < <(awk '/^cpu /{t=0;for(i=2;i<=NF;i++)t+=$i;print t,($5+$6);exit}' /proc/stat)
    memt=$(awk '/^MemTotal/{print $2*1024}' /proc/meminfo)
    mema=$(awk '/^MemAvailable/{print $2*1024}' /proc/meminfo)
    memu=$((memt-mema))
    upt=$(awk '{print int($1)}' /proc/uptime)
    read -r hrx htx < <(awk 'NR>2{sub(/:/," ");if($1!="lo"){rx+=$2;tx+=$10}}END{print rx+0,tx+0}' /proc/net/dev)
    local cver=""
    [[ -x "${config_dir}/leech" ]] && cver=$("${config_dir}/leech" -v 2>/dev/null | head -1 | tr -d '"\\')
    printf '{"host":{"cpu_total":%s,"cpu_idle":%s,"mem_used":%s,"mem_total":%s,"rx_bytes":%s,"tx_bytes":%s,"uptime":%s,"ncpu":%s,"core":"%s"},"tunnels":[' \
        "${cput:-0}" "${cpui:-0}" "${memu:-0}" "${memt:-0}" "${hrx:-0}" "${htx:-0}" "${upt:-0}" "${ncpu:-1}" "${cver}"
    local first=1 f name typ port active pid mem cpuns rx tx conns dir transport remote
    for f in "${config_dir}"/{iran,kharej}*.toml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .toml)
        [[ "$name" =~ ^(iran|kharej)([0-9]+)$ ]] || continue
        typ="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
        # transport + (client's) remote let the panel auto-discover tunnels across nodes
        # and detect a re-tunnel to a different server made outside the panel.
        transport=$(awk -F'"' '/^type = /{print $2; exit}' "$f" 2>/dev/null)
        remote=""; [[ "$typ" == kharej ]] && remote=$(awk -F'"' '/^remote_addr = /{print $2; exit}' "$f" 2>/dev/null)
        systemctl is-active --quiet "leech-${name}" && active=true || active=false
        mem=$(systemctl show "leech-${name}" -p MemoryCurrent --value 2>/dev/null)
        cpuns=$(systemctl show "leech-${name}" -p CPUUsageNSec --value 2>/dev/null)
        [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
        [[ "$cpuns" =~ ^[0-9]+$ ]] || cpuns=0
        # tunnel-port sockets: server listens (sport), client dials (dport)
        dir=sport; [[ "$typ" == kharej ]] && dir=dport
        # Throughput: prefer systemd per-unit IP accounting — it counts ALL of the
        # unit's traffic (TCP, UDP/kcp, raw/ipx) so it works for every transport, unlike
        # ss which only sees TCP. Enable it once if it's off (live, no restart).
        rx=""; tx=""
        if [[ "$(systemctl show "leech-${name}" -p IPAccounting --value 2>/dev/null)" != "yes" ]]; then
            systemctl set-property "leech-${name}" IPAccounting=yes 2>/dev/null || true
        fi
        local ing egr
        ing=$(systemctl show "leech-${name}" -p IPIngressBytes --value 2>/dev/null)
        egr=$(systemctl show "leech-${name}" -p IPEgressBytes --value 2>/dev/null)
        if [[ "$ing" =~ ^[0-9]+$ && "$egr" =~ ^[0-9]+$ ]]; then
            rx=$ing; tx=$egr   # ingress = download (rx), egress = upload (tx)
        else
            # fallback for TCP transports before accounting has warmed up
            read -r rx tx < <(ss -Htni "$dir = :$port" 2>/dev/null | awk '
                match($0,/bytes_received:[0-9]+/){r+=substr($0,RSTART+15,RLENGTH-15)}
                match($0,/bytes_sent:[0-9]+/){s+=substr($0,RSTART+11,RLENGTH-11)}
                END{print r+0,s+0}')
        fi
        # connections: TCP established on the tunnel port, plus the raw UDP socket for
        # connectionless carriers (kcp) so an active UDP tunnel shows at least its session.
        conns=$(ss -Htn "$dir = :$port" 2>/dev/null | grep -c ESTAB)
        [[ "${conns:-0}" -eq 0 ]] && [[ -n "$(ss -Huan "$dir = :$port" 2>/dev/null)" ]] && conns=1
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"type":"%s","port":%s,"active":%s,"cpu_ns":%s,"mem":%s,"rx_bytes":%s,"tx_bytes":%s,"conns":%s,"transport":"%s","remote":"%s"}' \
            "$typ" "$port" "$active" "$cpuns" "$mem" "${rx:-0}" "${tx:-0}" "${conns:-0}" "${transport}" "${remote}"
    done
    printf ']}\n'
}

case "${1:-}" in
    --create) panel_create "${2:?usage: --create <server|client>}"; exit $? ;;
    --rm)     panel_rm     "${2:?usage: --rm <type><port>}";        exit $? ;;
    --list)   panel_list;   exit $? ;;
    --stats)  panel_stats;  exit $? ;;
esac

while true; do
    display_menu
    read_option
done

