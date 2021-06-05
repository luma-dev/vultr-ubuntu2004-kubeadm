#!/bin/bash

set -euo pipefail

function ipv4mask_to_num {
  local ipv4mask=$1
  local arr=(${ipv4mask//./ })
  local num=0
  for n in ${arr[@]}; do
    local bin=$(echo "obase=2;$n" | bc)
    local cnt1=$(echo -n $bin | sed -e 's/0//g' | wc -c)
    (( num += cnt1 ))
  done
  echo -n $num
}

{
useradd --home-dir /home/work --shell /bin/bash --create-home work
usermod -aG sudo work
sed -i -e 's/^PermitRootLogin\s.*$/PermitRootLogin no/g' /etc/ssh/sshd_config
sed -i -e 's/^\s*#\?\s*PasswordAuthentication\s.*$/PasswordAuthentication no/g' /etc/ssh/sshd_config
sudo -u work mkdir -p /home/work/.ssh
cp /root/.ssh/authorized_keys /home/work/.ssh/authorized_keys
chown -R work:work /home/work
echo "work    ALL=NOPASSWD: ALL" >> /etc/sudoers
service ssh reload

# https://www.vultr.com/docs/how-to-configure-a-private-network-on-ubuntu
# https://www.vultr.com/metadata/#using_the_api
MAC_ADDR="$(ip addr | grep '^[[:digit:]]\+: ens7:' -A 1 | tail -n 1 | awk '{ print $2 }')"
PRIVATE_IP="$(curl http://169.254.169.254/v1/interfaces/1/ipv4/address)"
PRIVATE_IP_MASK="$(curl http://169.254.169.254/v1/interfaces/1/ipv4/netmask)"
PRIVATE_IP_MASK_NUM="$(ipv4mask_to_num "$PRIVATE_IP_MASK")"
cat <<EOF >> "/home/work/.bashrc"
export MAC_ADDR="$MAC_ADDR"
export PRIVATE_IP="$PRIVATE_IP"
export PRIVATE_IP_MASK="$PRIVATE_IP_MASK"
export PRIVATE_IP_MASK_NUM="$PRIVATE_IP_MASK_NUM"
EOF
cat <<EOF >> /etc/netplan/10-ens7.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens7:
      match:
        macaddress: ${MAC_ADDR}
      mtu: 1450
      dhcp4: no
      addresses: [${PRIVATE_IP}/${PRIVATE_IP_MASK_NUM}]
EOF
netplan apply
}

cat <<'END_OF_WORK' > /home/work/init.sh
{
set -euo pipefail
cd "$HOME"

## initialize
sudo apt-get update

## install network tools
sudo apt-get install -y net-tools ifstat nmap

## install necessary packages
sudo apt-get install -y unzip

# kubeadm
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# go
GO_VERSION=1.16.4
wget "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
rm -f "go${GO_VERSION}.linux-amd64.tar.gz"
echo 'export PATH="$PATH:/usr/local/go/bin"' >> "$HOME/.bashrc"
export PATH="$PATH:/usr/local/go/bin"
go version

# docker
sudo apt-get install -y docker.io

## # containerd
## cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
## overlay
## br_netfilter
## EOF
## 
## sudo modprobe overlay
## sudo modprobe br_netfilter
## 
## cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
## net.bridge.bridge-nf-call-iptables  = 1
## net.bridge.bridge-nf-call-ip6tables = 1
## net.ipv4.ip_forward                 = 1
## EOF
## 
## # Apply sysctl params without reboot
## sudo sysctl --system
## 
## CONTAINERD_VERSION="1.5.0"
## wget "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
## tar xvf "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
## sudo cp ./bin/containerd /usr/local/bin
## rm -f "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
## rm -rf bin
## 
## wget "https://github.com/containerd/containerd/archive/v${CONTAINERD_VERSION}.zip"
## unzip "v${CONTAINERD_VERSION}.zip"
## sudo cp "containerd-${CONTAINERD_VERSION}/containerd.service" /etc/systemd/system
## rm -f "v${CONTAINERD_VERSION}.zip"
## rm -rf "containerd-${CONTAINERD_VERSION}"
## sudo chmod 755 /etc/systemd/system/containerd.service
## 
## containerd config default \
##   | sed \
##   -e 's/SystemdCgroup\s\+=\s\+false/SystemdCgroup = true/' \
##   | sudo tee /etc/containerd/config.toml
## 
## sudo systemctl enable containerd.service
## sudo systemctl start containerd.service

sudo apt-get install -y apt-transport-https ca-certificates curl
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo swapoff -a

sudo kubeadm config images pull

cat <<'EOF' > ./kubeadm-init.sh
#!/bin/sh

sudo kubeadm init \
  --apiserver-advertise-address $PRIVATE_IP \
  --control-plane-endpoint $PRIVATE_IP \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=NumCPU,Mem

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
EOF

chmod +x ./kubeadm-init.sh


cat <<'EOF' > ./kubeadm-leave.sh
#!/bin/bash

if test "$(hostname)" = master0; then
  echo "error: do not use this script in master0"
  exit 1
fi

sudo kubeadm reset --force
sudo systemctl stop kubelet
sudo systemctl stop docker
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/lib/kubelet/*
sudo rm -rf /etc/cni/
sudo ifconfig cni0 down
sudo ifconfig flannel.1 down
sudo ifconfig docker0 down
sudo ip link set cni0 down
sudo brctl delbr cni0
EOF

chmod +x ./kubeadm-leave.sh

cat <<'EOF' > ./show-crt-hash.sh
#!/bin/bash

if test ! "$(hostname)" = master0; then
  echo "error: do not use this script in nodes except master0"
  exit 1
fi

openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey \
  | openssl rsa -pubin -outform der \
  | openssl dgst -sha256 -hex
EOF

chmod +x ./show-crt-hash.sh

}
END_OF_WORK

chown work:work /home/work/init.sh
chmod +x /home/work/init.sh

sudo -u work /bin/bash /home/work/init.sh

# /proc/sys/net/ipv4/ip_forward
# --cri-socket /run/containerd/containerd.sock
# --ignore-preflight-errors=NumCPU
