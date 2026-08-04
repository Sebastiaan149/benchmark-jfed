#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:-server}"

base_packages=(
  build-essential
  ca-certificates
  coreutils
  curl
  g++
  git
  iperf3
  iputils-ping
  iproute2
  iptables
  jq
  make
  python3
  procps
  python3-matplotlib
  python3-pandas
  rsync
  sysstat
  tcpdump
  unzip
)

server_packages=(
  autoconf
  gnulib
  gzip
  docker.io
  libserd-dev
  libtool
  maven
  openjdk-21-jdk
  pkg-config
  python3-pip
  python3-venv
)

sudo apt-get update

case "$ROLE" in
  server)
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${base_packages[@]}" "${server_packages[@]}"
    ;;
  client)
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${base_packages[@]}"
    ;;
  *)
    echo "Usage: ROLE=server|client $0" >&2
    exit 1
    ;;
esac

curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
sudo npm install -g yarn@1.22.22

node --version
yarn --version
if [[ "$ROLE" == "server" ]]; then
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  java -version
  mvn --version | sed -n '1,2p'
fi
