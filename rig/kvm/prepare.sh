#!/bin/bash
# Boots a guest shaped like the box: 1 vCPU, 2 GB, no swap, Ubuntu 24.04 with its 6.8 kernel, reached over a virtio
# network device from the load generator on the host. Then installs and builds each entry inside it, as the box would.
#   prepare.sh WORK_DIR ENTRY_DIR...
set -euo pipefail
work="$1"
shift
mkdir -p "$work"
cd "$work"
GUEST=10.77.0.2

sudo chmod 666 /dev/kvm
curl -fsSL --retry 3 -o base.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img create -q -f qcow2 -F qcow2 -b base.img guest.qcow2 16G
ssh-keygen -q -t ed25519 -N '' -f key
cat > user-data <<EOF
#cloud-config
users:
  - name: deploy
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat key.pub)
package_update: false
EOF
cat > network-config <<EOF
version: 2
ethernets:
  nic:
    match:
      name: "en*"
    addresses: [$GUEST/16]
    routes:
      - to: default
        via: 10.77.0.1
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
EOF
printf 'instance-id: box\nlocal-hostname: box\n' > meta-data
cloud-localds -N network-config seed.img user-data meta-data

sudo ip tuntap add tap0 mode tap
sudo ip addr add 10.77.0.1/16 dev tap0
# Each client address gives another 60,000 connections to the one server port.
for i in $(seq 0 31); do sudo ip addr add "10.77.1.$i/16" dev tap0; done
sudo ip link set tap0 up
# The load traffic is untracked, as on the box. The guest's own way out, for installing, is translated.
sudo iptables -t raw -A PREROUTING -i tap0 -d 10.77.1.0/24 -j NOTRACK
sudo iptables -t raw -A OUTPUT -o tap0 -s 10.77.1.0/24 -j NOTRACK
sudo sysctl -q -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 10.77.0.0/16 ! -d 10.77.0.0/16 -j MASQUERADE
sudo iptables -I FORWARD -i tap0 -j ACCEPT
sudo iptables -I FORWARD -o tap0 -j ACCEPT
sudo sysctl -q -w fs.nr_open=2097152 net.ipv4.ip_local_port_range="1024 65000"

sudo taskset -c 0,1 qemu-system-x86_64 -enable-kvm -cpu host -smp 1 -m 2048 -display none -daemonize \
  -serial file:console.log -pidfile qemu.pid \
  -drive file=guest.qcow2,if=virtio,cache=none,aio=native -drive file=seed.img,if=virtio,format=raw \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on -device virtio-net-pci,netdev=n0

SSH=(ssh -i key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "deploy@$GUEST")
for _ in $(seq 1 60); do
  "${SSH[@]}" true 2> /dev/null && break
  sleep 5
done
"${SSH[@]}" 'cloud-init status --wait > /dev/null 2>&1; echo "GUEST kernel=$(uname -r) cpus=$(nproc) mem_mb=$(free -m | awk "/Mem:/ {print \$2}") swap_mb=$(free -m | awk "/Swap:/ {print \$2}") cpu=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)"'
# The packages the challenge's seed and health checks need, as a clean box would install them.
"${SSH[@]}" 'sudo apt-get update -qq && sudo apt-get install -y -qq time > /dev/null'

for entry in "$@"; do
  name=$(basename "$entry")
  tar -C "$entry" -czf - . | "${SSH[@]}" "mkdir -p entries/$name && tar -C entries/$name -xzf -"
  "${SSH[@]}" "sudo bash entries/$name/install.sh 2>&1 | tail -3 | cut -c1-200; echo \"INSTALLED $name \${PIPESTATUS[0]}\""
  "${SSH[@]}" "cd entries/$name && /usr/bin/time -f \"BUILD $name seconds=%e resident_kb=%M exit=%x\" bash build.sh 2>&1 | tail -6 | cut -c1-200"
  # An entry that didn't build would only give numbers from a dead port.
  "${SSH[@]}" "test -x entries/$name/bin/server || test -x entries/$name/server" || { echo "NOT BUILT $name"; exit 1; }
done
"${SSH[@]}" 'df -h / | tail -1; free -m | head -2'
