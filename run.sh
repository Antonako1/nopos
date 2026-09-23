#!/usr/bin/env bash
# set -euo pipefail


# sudo ip addr add 192.168.10.1/24 dev eth1 
./build.sh
# sudo ip link set eth1 up
# ip addr show eth1

#sudo ip addr flush dev eth2
#sudo ip addr add 192.168.10.1/24 dev eth2
#sudo ip link set eth2 up

sudo IFACE=eth0 SERVER_IP=192.168.10.1 ./pxe/serve.sh