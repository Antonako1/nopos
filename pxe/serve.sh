#!/usr/bin/env bash
# =============================================================================
# pxe/serve.sh — Serve NopOS over PXE (TFTP + HTTP + optional proxyDHCP).
#
# Chain:  client -> iPXE (via TFTP) -> boot.ipxe menu (via HTTP)
#         -> memdisk + output/floppy.img (via HTTP) -> boot via INT 13h.
# memdisk emulates a floppy drive, so the OS boots exactly as it does in QEMU.
#
# Designed for WSL2 with an EXISTING DHCP server. dnsmasq runs in "proxy" mode:
# it never hands out IP addresses, it only advertises PXE boot info, so it
# will not conflict with your DHCP server.
#
# Usage:
#   sudo ./pxe/serve.sh                 # proxyDHCP + TFTP + HTTP (default)
#   sudo DHCP_MODE=off ./pxe/serve.sh   # TFTP + HTTP only (prints manual config)
#   sudo IFACE=eth0 ./pxe/serve.sh      # override detected interface
#
# WSL2 REQUIREMENT (Windows 11 22H2+): PXE clients on the LAN must be able to
# reach this server, so enable mirrored networking in ~/.wslconfig:
#   [wsl2]
#   networkingMode=mirrored
# then run: wsl --shutdown  (and restart WSL).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

TFTP_ROOT="${TFTP_ROOT:-$SCRIPT_DIR/tftp}"
HTTP_ROOT="${HTTP_ROOT:-$SCRIPT_DIR/www}"
HTTP_PORT="${HTTP_PORT:-80}"

IFACE="${IFACE:-}"
SERVER_IP="${SERVER_IP:-}"
SUBNET="${SUBNET:-}"            # proxyDHCP scope; auto-detected if empty
DHCP_MODE="${DHCP_MODE:-proxy}" # "proxy" | "off"

FLOPPY="$ROOT_DIR/output/floppy.img"
DNSMASQ_CONF="$SCRIPT_DIR/dnsmasq.conf"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"
}

check_deps() {
    local missing=()
    for bin in dnsmasq python3 curl; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing: ${missing[*]}. Install with: sudo apt install -y ${missing[*]}"
    fi
}

detect_iface() {
    if [ -z "$IFACE" ]; then
        IFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}')"
    fi
    [ -n "$IFACE" ] || IFACE="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $2}')"
    [ -n "$IFACE" ] || die "could not detect network interface; set IFACE=eth0"
}

detect_ip() {
    SERVER_IP="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [ -n "$SERVER_IP" ] || die "no IPv4 address on $IFACE; set SERVER_IP=x.x.x.x"
}

detect_subnet() {
    [ -n "$SUBNET" ] && return 0
    local cidr
    cidr="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
    SUBNET="$(python3 - "$cidr" <<'EOF'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network.network_address)
EOF
)"
}

# ── iPXE bootloaders (BIOS + UEFI) into the TFTP root ──────────────────────
fetch_bootloaders() {
    mkdir -p "$TFTP_ROOT"
    local pkg=/usr/lib/ipxe
    if [ ! -f "$TFTP_ROOT/undionly.kpxe" ]; then
        if [ -f "$pkg/undionly.kpxe" ]; then
            cp "$pkg/undionly.kpxe" "$TFTP_ROOT/undionly.kpxe"
        else
            log "downloading undionly.kpxe"
            curl -fsSL -o "$TFTP_ROOT/undionly.kpxe" https://boot.ipxe.org/undionly.kpxe
        fi
    fi
    if [ ! -f "$TFTP_ROOT/ipxe.efi" ]; then
        if [ -f "$pkg/ipxe.efi" ]; then
            cp "$pkg/ipxe.efi" "$TFTP_ROOT/ipxe.efi"
        else
            log "downloading ipxe.efi"
            curl -fsSL -o "$TFTP_ROOT/ipxe.efi" https://boot.ipxe.org/i386-efi/ipxe-legacy.efi
        fi
    fi
}

find_memdisk() {
    local p
    for p in \
        /usr/lib/syslinux/modules/bios/memdisk \
        /usr/lib/syslinux/memdisk \
        /usr/share/syslinux/memdisk; do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# ── HTTP root: memdisk, floppy image, iPXE menu ─────────────────────────────
prepare_http() {
    mkdir -p "$HTTP_ROOT"

    local memdisk
    memdisk="$(find_memdisk)" || \
        die "memdisk not found. Install with: sudo apt install -y syslinux-common"

    cp -f "$memdisk" "$HTTP_ROOT/memdisk"

    [ -f "$FLOPPY" ] || die "$FLOPPY not found. Run ./build.sh first."
    cp -f "$FLOPPY" "$HTTP_ROOT/floppy.img"

    write_menu
}

write_menu() {
    local base="http://$SERVER_IP:$HTTP_PORT"
    cat > "$HTTP_ROOT/boot.ipxe" <<'EOF'
#!ipxe

:start
menu NopOS PXE Boot
item nopos  Boot NopOS (floppy.img via memdisk)
item shell  Drop to iPXE shell
item reboot Reboot
choose --default nopos --timeout 5000 target || goto reboot
goto ${target}

:nopos
kernel @@HTTP_BASE@@/memdisk raw
initrd @@HTTP_BASE@@/floppy.img
boot || goto failed

:shell
shell || goto start

:reboot
reboot

:failed
echo Boot failed. Returning to menu.
goto start
EOF
    sed -i "s|@@HTTP_BASE@@|$base|g" "$HTTP_ROOT/boot.ipxe"
}

# ── dnsmasq proxyDHCP + TFTP config ─────────────────────────────────────────
write_dnsmasq_conf() {
    cat > "$DNSMASQ_CONF" <<EOF
# Generated by pxe/serve.sh — proxyDHCP + TFTP. Does NOT assign IP addresses.
port=0
interface=$IFACE
log-dhcp

enable-tftp
tftp-root=$TFTP_ROOT

# Proxy mode: only answer PXE clients, never hand out leases.
#dhcp-range=$SUBNET,proxy
dhcp-range=192.168.10.100,192.168.10.200,1h

# Match client architecture and pick the right iPXE image.
dhcp-match=set:bios,option:client-arch,0
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:bios,undionly.kpxe
dhcp-boot=tag:efi-x86_64,ipxe.efi
dhcp-boot=tag:ipxe,http://$SERVER_IP:$HTTP_PORT/boot.ipxe
dhcp-boot=undionly.kpxe

# Once iPXE is running (it sends DHCP option 175), hand it the HTTP menu.
dhcp-match=set:ipxe,175
dhcp-boot=tag:ipxe,http://$SERVER_IP:$HTTP_PORT/boot.ipxe
EOF
}

print_manual_proxydhcp() {
    cat <<EOF

ProxyDHCP is OFF. Add the following to your existing DHCP server so PXE
clients boot this server (adjust syntax to your DHCP server):

  # Next-server (TFTP server) and boot filename for legacy BIOS:
  option tftp-server-name "$SERVER_IP";
  option bootfile-name "undionly.kpxe";
  # ...or for UEFI x86_64 clients, "ipxe.efi".

EOF
}

cleanup() {
    trap - EXIT INT TERM
    [ -n "${HTTP_PID:-}" ]   && kill "$HTTP_PID"   2>/dev/null || true
    [ -n "${DNSMASQ_PID:-}" ] && kill "$DNSMASQ_PID" 2>/dev/null || true
}

start_servers() {
    trap cleanup EXIT INT TERM

    if [ "$DHCP_MODE" = "proxy" ]; then
        dnsmasq -C "$DNSMASQ_CONF" --no-daemon &
        DNSMASQ_PID=$!
        log "dnsmasq proxyDHCP + TFTP started on $IFACE (pid $DNSMASQ_PID)"
    else
        print_manual_proxydhcp
    fi

    python3 -m http.server "$HTTP_PORT" --bind "$SERVER_IP" --directory "$HTTP_ROOT" &
    HTTP_PID=$!
    log "HTTP serving $HTTP_ROOT on http://$SERVER_IP:$HTTP_PORT (pid $HTTP_PID)"

    echo
    log "Ready. Boot a client from PXE (BIOS/CSM required; the OS is 32-bit)."
    log "Press Ctrl+C to stop."
    echo

    wait "$HTTP_PID" ${DNSMASQ_PID:-} 2>/dev/null || true
}

# ── main ─────────────────────────────────────────────────────────────────────
need_root "$@"
check_deps
detect_iface
detect_ip
detect_subnet
log "interface: $IFACE  ip: $SERVER_IP  subnet: $SUBNET  mode: $DHCP_MODE"
fetch_bootloaders
prepare_http
write_dnsmasq_conf
start_servers
