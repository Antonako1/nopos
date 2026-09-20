#!/usr/bin/env bash
set -euo pipefail

./build.sh
sudo IFACE=eth1 SERVER_IP=192.168.10.1 ./pxe/serve.sh