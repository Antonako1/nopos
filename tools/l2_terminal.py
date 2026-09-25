#!/usr/bin/env python3
"""
================================================================================
NopOS Advanced Layer 2 Terminal CLI (tools/l2_terminal.py)
================================================================================

Description:
  An interactive, multi-threaded host-side CLI tool for testing raw Layer 2 
  Ethernet frame communication with NopOS on physical hardware or virtual networks.

Prerequisites & Requirements:
  - Python 3.7+
  - Scapy package:
      pip install scapy

  - Windows Prerequisites:
      Requires Npcap (or WinPcap) installed on the system (included with Wireshark).
      Run your Command Prompt / PowerShell as Administrator if adapter access is restricted.

  - Linux Prerequisites:
      Run with elevated privileges to access raw network sockets:
      sudo python3 tools/l2_terminal.py

Usage & Running Instructions:
  1. Quick Start:
      python tools/l2_terminal.py

  2. Custom Target MAC and Interface:
      python tools/l2_terminal.py --mac 00:03:47:12:34:56 --iface Ethernet

Interactive Local Commands (within the terminal CLI):
  - rd [filename] / redir [filename]
      Toggle file redirection.
      Example: 'rd cap.txt' starts writing incoming packet data to cap.txt.
      Example: 'rd' stops redirection and resumes live terminal printing.

  - mac [address]
      View or change target NopOS MAC address. Example: 'mac 00:03:47:AA:BB:CC'

  - iface [name]
      View or change local network interface adapter name. Example: 'iface eth0'

  - type [hex_val]
      Set default EtherType. Example: 'type 0806' (ARP) or 'type 0800' (IPv4)

  - hex / ascii
      Toggle incoming payload view mode between Hex dump and ASCII text.

  - status / info
      Display current interface, MAC, active file redirection, and TX/RX stats.

  - clear / cls
      Clear terminal screen.

  - help / ?
      Display command reference menu.

  - exit / quit
      Exit application.
================================================================================
"""

import sys
import os
import time
import argparse
import threading
from datetime import datetime

try:
    from scapy.all import Ether, sendp, sniff, Raw, get_working_ifaces
except ImportError:
    print("[!] ERROR: Scapy library is required.")
    print("    Install it using: pip install scapy")
    sys.exit(1)


ETHERTYPES = {
    0x0800: "IPv4",
    0x0806: "ARP",
    0x86DD: "IPv6",
    0x8100: "802.1Q VLAN",
    0x8847: "MPLS Unicast",
    0x8863: "PPPoE Discovery",
    0x8864: "PPPoE Session",
    0x88CC: "LLDP",
    0x88F7: "PTP (IEEE 1588)"
}

def get_ethertype_name(val):
    name = ETHERTYPES.get(val, "Custom/Unknown")
    return f"0x{val:04X} ({name})"


class L2Terminal:
    def __init__(self, target_mac="00:03:47:12:34:56", iface=None):
        if os.name == "nt":
            os.system("")  # Enable Windows VT100 ANSI processing
        self.target_mac = target_mac.lower()
        self.iface = iface or self.detect_default_iface()
        self.ethertype = 0x0800
        self.hex_mode = False
        self.redir_file = None
        self.redir_filename = None
        self.rx_count = 0
        self.tx_count = 0
        self.running = True
        self.lock = threading.Lock()

    def detect_default_iface(self):
        try:
            ifaces = get_working_ifaces()
            if ifaces:
                return ifaces[0].name
        except Exception:
            pass
        return "Ethernet" if os.name == "nt" else "eth0"

    def toggle_redirection(self, filename=None):
        with self.lock:
            if self.redir_file:
                old_name = self.redir_filename
                self.redir_file.close()
                self.redir_file = None
                self.redir_filename = None
                print(f"\n[+] Redirection STOPPED. Log saved to '{old_name}'. Output restored to terminal.")
            else:
                if not filename or len(filename.strip()) == 0:
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                    filename = f"l2_capture_{timestamp}.txt"
                filename = filename.strip()
                try:
                    self.redir_file = open(filename, "a", encoding="utf-8")
                    self.redir_filename = filename
                    print(f"\n[+] Redirection ACTIVE -> Writing all incoming packet data to '{filename}'.")
                except Exception as e:
                    print(f"\n[-] ERROR opening file '{filename}': {e}")

    def handle_packet(self, pkt):
        if Ether not in pkt:
            return

        src_mac = pkt[Ether].src.lower()
        dst_mac = pkt[Ether].dst.lower()

        # Match packets sent by or to NopOS MAC
        if self.target_mac != "ff:ff:ff:ff:ff:ff":
            if src_mac != self.target_mac and dst_mac != self.target_mac:
                return

        self.rx_count += 1
        payload_bytes = bytes(pkt[Ether].payload)
        timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]

        if self.hex_mode:
            payload_str = payload_bytes.hex(' ')
        else:
            try:
                payload_str = payload_bytes.decode('utf-8', errors='ignore')
            except Exception:
                payload_str = str(payload_bytes)

        type_formatted = get_ethertype_name(pkt[Ether].type)
        log_entry = (
            f"[{timestamp}] [RX {src_mac} -> {dst_mac}] "
            f"Type: {type_formatted} | Len: {len(payload_bytes)}B | Payload: {payload_str}\n"
        )

        with self.lock:
            if self.redir_file:
                self.redir_file.write(log_entry)
                self.redir_file.flush()
            else:
                sys.stdout.write("\n" + f"\033[92m{log_entry.strip()}\033[0m\n")
                sys.stdout.flush()

    def sniffer_loop(self):
        while self.running:
            try:
                filter_str = ""
                if self.target_mac != "ff:ff:ff:ff:ff:ff":
                    filter_str = f"ether src {self.target_mac} or ether dst {self.target_mac}"
                sniff(
                    iface=self.iface,
                    prn=self.handle_packet,
                    filter=filter_str,
                    store=0,
                    stop_filter=lambda p: not self.running
                )
            except Exception as e:
                if self.running:
                    time.sleep(2)

    def print_status(self):
        print("\n=== L2 Terminal Current Configuration & Status ===")
        print(f"  Target MAC:        {self.target_mac}")
        print(f"  Local Interface:   {self.iface}")
        print(f"  Default EtherType: {get_ethertype_name(self.ethertype)}")
        print(f"  Payload Display:   {'HEX' if self.hex_mode else 'ASCII'}")
        print(f"  Redirection:       {'ACTIVE (' + self.redir_filename + ')' if self.redir_file else 'DISABLED (Terminal Output)'}")
        print(f"  Packets RX/TX:     {self.rx_count} Received / {self.tx_count} Sent")
        print("===================================================\n")

    def print_help(self, cmd_name=None):
        if not cmd_name:
            print("\n=== L2 Terminal Interactive Commands ===")
            print("  rd [filename] / redir [filename] - Toggle file logging (e.g. 'rd cap.txt' -> 'rd')")
            print("  mac <address>                    - Set target MAC (e.g. 'mac 00:03:47:12:34:56')")
            print("  iface <name>                     - Set network adapter interface")
            print("  type <hex>                       - Set EtherType (e.g. 'type 0806' or 'type 0800')")
            print("  hex / ascii                      - Toggle hex vs ascii payload viewing mode")
            print("  status / info                    - Display status & statistics")
            print("  clear / cls                      - Clear terminal screen")
            print("  help [command] / ? [command]     - Display help menu or specific command help")
            print("  exit / quit                      - Exit CLI")
            print("  <any message>                    - Transmit Ethernet frame to NopOS\n")
            print("Type 'help <command>' (e.g. 'help rd', 'help type') for detailed command help.\n")
            return

        cmd = cmd_name.strip().lower()
        if cmd in ("rd", "redir", "redirect"):
            print("\n--- Command: redir / rd [filename] ---")
            print("Description: Diverts incoming packet output to a specified disk file.")
            print("Usage:")
            print("  rd capture.txt  - Starts appending all incoming packet logs to capture.txt.")
            print("  rd              - Stops file redirection and restores live output to screen.\n")
        elif cmd in ("mac", "setmac"):
            print("\n--- Command: mac [address] ---")
            print("Description: Displays or sets the target NopOS MAC address.")
            print("Usage:")
            print("  mac                     - Show current target MAC address.")
            print("  mac 00:03:47:12:34:56   - Set target MAC address.")
            print("  mac ff:ff:ff:ff:ff:ff   - Listen to all broadcast/multicast frames.\n")
        elif cmd in ("iface", "if"):
            print("\n--- Command: iface [name] ---")
            print("Description: Displays or updates the host network interface adapter.")
            print("Usage:")
            print("  iface           - Show current interface.")
            print("  iface Ethernet  - Set adapter to 'Ethernet' (Windows).")
            print("  iface eth0      - Set adapter to 'eth0' (Linux).\n")
        elif cmd in ("type", "ethertype"):
            print("\n--- Command: type [hex_val] ---")
            print("Description: Displays or sets the default EtherType hex value for outgoing frames.")
            print("Usage:")
            print("  type        - Show current default EtherType.")
            print("  type 0800   - Set EtherType to 0x0800 (IPv4).")
            print("  type 0806   - Set EtherType to 0x0806 (ARP).")
            print("  type 86DD   - Set EtherType to 0x86DD (IPv6).\n")
        elif cmd in ("hex", "ascii"):
            print("\n--- Command: hex / ascii ---")
            print("Description: Toggles incoming packet payload format between raw hex bytes and ASCII text.\n")
        elif cmd in ("status", "info", "stat"):
            print("\n--- Command: status / info ---")
            print("Description: Displays current interface, MAC, active redirection, and TX/RX packet statistics.\n")
        elif cmd in ("clear", "cls"):
            print("\n--- Command: clear / cls ---")
            print("Description: Clears the terminal screen.\n")
        else:
            print(f"\n[-] Unknown command '{cmd_name}'. Type 'help' for full command list.\n")

    def process_command(self, line):
        line = line.strip()
        if not line:
            return

        tokens = line.split(maxsplit=1)
        cmd = tokens[0].lower()
        args = tokens[1].strip() if len(tokens) > 1 else ""

        if cmd in ("rd", "redir", "redirect"):
            self.toggle_redirection(args)
        elif cmd in ("mac", "setmac"):
            if args:
                self.target_mac = args.lower()
                print(f"[+] Target MAC updated to: {self.target_mac}")
            else:
                print(f"[+] Target MAC: {self.target_mac}")
        elif cmd in ("iface", "if"):
            if args:
                self.iface = args
                print(f"[+] Network interface updated to: {self.iface}")
            else:
                print(f"[+] Network interface: {self.iface}")
        elif cmd in ("type", "ethertype"):
            if args:
                try:
                    self.ethertype = int(args, 16)
                    print(f"[+] Default EtherType updated to: {get_ethertype_name(self.ethertype)}")
                except ValueError:
                    print("[-] ERROR: Invalid hex EtherType value (e.g. use 0800 or 0806).")
            else:
                print(f"[+] Default EtherType: {get_ethertype_name(self.ethertype)}")
        elif cmd == "hex":
            self.hex_mode = True
            print("[+] Payload view set to HEX.")
        elif cmd == "ascii":
            self.hex_mode = False
            print("[+] Payload view set to ASCII.")
        elif cmd in ("status", "info", "stat"):
            self.print_status()
        elif cmd in ("clear", "cls"):
            os.system("cls" if os.name == "nt" else "clear")
        elif cmd in ("help", "?"):
            self.print_help(args if args else None)
        elif cmd in ("exit", "quit"):
            self.running = False
            if self.redir_file:
                self.redir_file.close()
            print("Exiting L2 Terminal.")
            sys.exit(0)
        else:
            # Transmit raw Layer 2 Ethernet frame
            try:
                pkt = Ether(dst=self.target_mac, type=self.ethertype) / Raw(load=line.encode('utf-8'))
                sendp(pkt, iface=self.iface, verbose=False)
                self.tx_count += 1
                print(f"\033[93m[TX Sent -> {self.target_mac}]\033[0m Type: {get_ethertype_name(self.ethertype)} | '{line}' ({len(line)}B)")
            except Exception as e:
                print(f"[-] ERROR transmitting frame: {e}")

    def run(self):
        print("==========================================================")
        print("         NopOS Advanced Layer 2 Interactive CLI Terminal  ")
        print("==========================================================")
        self.print_status()
        print("Type 'help' for local commands. Type any text and hit Enter to transmit.\n")

        # Start sniffer thread
        sniffer_thread = threading.Thread(target=self.sniffer_loop, daemon=True)
        sniffer_thread.start()

        # Command input loop
        while self.running:
            try:
                prompt = "\033[94mSend > \033[0m"
                user_input = input(prompt)
                self.process_command(user_input)
            except (KeyboardInterrupt, EOFError):
                print("\n[+] Exiting L2 Terminal.")
                self.running = False
                if self.redir_file:
                    self.redir_file.close()
                break


def main():
    if os.name == "nt":
        os.system("")  # Enable VT100 ANSI sequence processing in Windows cmd.exe / PowerShell
    parser = argparse.ArgumentParser(description="NopOS Layer 2 Terminal CLI")
    parser.add_argument("--mac", default="00:0C:76:3A:9E:9C", help="Target NopOS MAC address")
    parser.add_argument("--iface", default=None, help="Host network interface (e.g. Ethernet, eth0)")
    args = parser.parse_args()

    term = L2Terminal(target_mac=args.mac, iface=args.iface)
    term.run()


if __name__ == "__main__":
    main()
