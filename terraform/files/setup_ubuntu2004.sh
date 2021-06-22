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
export MAC_ADDR="$(curl http://169.254.169.254/v1/interfaces/1/mac)"

export PUBLIC_IP4="$(curl http://169.254.169.254/v1/interfaces/0/ipv4/address)"
export PUBLIC_IP4_MASK="$(curl http://169.254.169.254/v1/interfaces/0/ipv4/netmask)"
export PUBLIC_IP4_MASK_NUM="$(ipv4mask_to_num "$PUBLIC_IP4_MASK")"

export PUBLIC_IP6="$(curl http://169.254.169.254/v1/interfaces/0/ipv6/address)"
export PUBLIC_IP6_PREFIX="$(curl http://169.254.169.254/v1/interfaces/0/ipv6/prefix)"

export PRIVATE_IP4="$(curl http://169.254.169.254/v1/interfaces/1/ipv4/address)"
export PRIVATE_IP4_MASK="$(curl http://169.254.169.254/v1/interfaces/1/ipv4/netmask)"
export PRIVATE_IP4_MASK_NUM="$(ipv4mask_to_num "$PRIVATE_IP4_MASK")"

# flannel
# NOTE: This is defined in https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
export POD_CIDR_V4=10.244.0.0/16
export POD_CIDR_V6=2001:db8:42:0::/56

export SVC_CIDR_V4=10.96.0.0/16
export SVC_CIDR_V6=2001:db8:42:1::/112

cat <<'EOF' >> "/home/work/.bashrc"
test -f "$HOME/bash_vars.sh" && source "$HOME/bash_vars.sh"
EOF
cat <<EOF > "/home/work/bash_vars.sh"
export MAC_ADDR="$MAC_ADDR"

export PUBLIC_IP4="$PUBLIC_IP4"
export PUBLIC_IP4_MASK="$PUBLIC_IP4_MASK"
export PUBLIC_IP4_MASK_NUM="$PUBLIC_IP4_MASK_NUM"

export PUBLIC_IP6="$PUBLIC_IP6"
export PUBLIC_IP6_PREFIX="$PUBLIC_IP6_PREFIX"

export PRIVATE_IP4="$PRIVATE_IP4"
export PRIVATE_IP4_MASK="$PRIVATE_IP4_MASK"
export PRIVATE_IP4_MASK_NUM="$PRIVATE_IP4_MASK_NUM"

export POD_CIDR_V4="$POD_CIDR_V4"
export POD_CIDR_V6="$POD_CIDR_V6"

export SVC_CIDR_V4="$SVC_CIDR_V4"
export SVC_CIDR_V6="$SVC_CIDR_V6"
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
      addresses: [${PRIVATE_IP4}/${PRIVATE_IP4_MASK_NUM}]
EOF
netplan apply
}

cat <<'END_OF_INIT' > /home/work/init.sh
{
set -euo pipefail
cd "$HOME"
source "$HOME/bash_vars.sh"

## initialize
sudo apt-get update

## install network tools
sudo apt-get install -y net-tools ifstat nmap bridge-utils

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
net.ipv6.conf.all.forwarding        = 1
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


# kubelet ipv6 configuration

cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$PRIVATE_IP4,$PUBLIC_IP6
EOF


# cri-o

# Create the .conf file to load the modules at bootup
cat <<EOF | sudo tee /etc/modules-load.d/crio.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set up required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

sudo apt-get install -y curl jq tar
curl https://raw.githubusercontent.com/cri-o/cri-o/master/scripts/get | sudo bash

sudo rm -f /etc/cni/net.d/10-crio-*
sudo rm -f /etc/cni/net.d/10-crio.*
echo "unqualified-search-registries = ['docker.io']" | sudo tee /etc/containers/registries.conf

sudo systemctl enable crio
sudo systemctl start crio


sudo apt-get install -y apt-transport-https ca-certificates curl
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo swapoff -a

sudo kubeadm config images pull


if ! test -d scripts; then
  mkdir scripts
fi

cat <<'EOF' > ./scripts/kubeadm-init-master0.sh
#!/bin/sh

if test "$(hostname)" != master0; then
  echo "error: do not use this script in nodes except master0"
  exit 1
fi

SCRIPT_DIR="$(realpath "$(dirname "$0")")"

sudo snap install --classic helm

sudo kubeadm init \
  --apiserver-advertise-address $PRIVATE_IP4 \
  --control-plane-endpoint $PRIVATE_IP4 \
  --pod-network-cidr="$POD_CIDR_V4,$POD_CIDR_V6" \
  --service-cidr="$SVC_CIDR_V4,$SVC_CIDR_V6" \
  --upload-certs \
  --ignore-preflight-errors=NumCPU,Mem

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

bash "$SCRIPT_DIR/untaint-masters-for-schedule.sh"
bash "$SCRIPT_DIR/install-calico-master0.sh"
EOF


cat <<'EOF' > ./scripts/install-calico-master0.sh
#!/bin/bash

if test "$(hostname)" != master0; then
  echo "error: do not use this script in nodes except master0"
  exit 1
fi

kubectl apply -f https://raw.githubusercontent.com/luma-dev/k8s-manifests/main/calico-kubeadm-dualstack-vultr-private.yaml
EOF


cat <<'EOF' > ./scripts/untaint-masters-for-schedule.sh
kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl describe nodes | grep Taints
EOF


cat <<'EOF' > ./scripts/_kubeadm_input.sh
IS_KUBEADM_JOIN=
if [[ "$INPUT" =~ kubeadm[[:space:]]+join([[:space:]]|$) ]]; then
  IS_KUBEADM_JOIN=1
fi
IS_KUBEADM_JOIN_CONTROL_PLANE=
if [[ "$INPUT" =~ kubeadm[[:space:]]+join[[:space:]]+.*[[:space:]]--control-plane ]]; then
  IS_KUBEADM_JOIN_CONTROL_PLANE=1
fi
EOF


cat <<'EOF' > ./scripts/kubeadm-join-control-plane.sh
#!/bin/bash

if test "$(hostname)" = master0; then
  echo "error: do not use this script in master0"
  exit 1
fi

if test "$(hostname)" = ^worker; then
  echo "error: do not use this script in worker nodes"
  exit 1
fi

SCRIPT_DIR="$(realpath "$(dirname "$0")")"

INPUT="$(echo -n $@)"
source "$SCRIPT_DIR/_kubeadm_input.sh"


if test -z "$IS_KUBEADM_JOIN"; then
  echo "error: invalid input"
  echo "info: usage: ./scripts/kubeadm-join-control-plane.sh {{ paste here 'kubeadm join ... --control-plane ...' dropped by primary control plane }}"
  exit 1
fi

if test -z "$IS_KUBEADM_JOIN_CONTROL_PLANE"; then
  echo "error: supply join command for control plane"
  exit 1
fi

sudo $@ \
  --apiserver-advertise-address $PRIVATE_IP4 \
  --ignore-preflight-errors=NumCPU,Mem

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

bash "$SCRIPT_DIR/untaint-masters-for-schedule.sh"
EOF


cat <<'EOF' > ./scripts/kubeadm-join-worker.sh
#!/bin/bash

if test "$(hostname)" = ^master; then
  echo "error: do not use this script in master nodes"
  exit 1
fi

SCRIPT_DIR="$(realpath "$(dirname "$0")")"

INPUT="$(echo -n $@)"
source "$SCRIPT_DIR/_kubeadm_input.sh"

if test -z "$IS_KUBEADM_JOIN"; then
  echo "error: invalid input"
  echo "info: usage: ./scripts/kubeadm-join-worker.sh {{ paste here 'kubeadm join ...' dropped by primary control plane }}"
  exit 1
fi

if test -n "$IS_KUBEADM_JOIN_CONTROL_PLANE"; then
  echo "error: supply join command for worker node"
  exit 1
fi

sudo $@ \
  --ignore-preflight-errors=NumCPU,Mem
EOF


cat <<'EOF' > ./scripts/kubeadm-leave.sh
#!/bin/bash

sudo kubeadm reset --force
sudo systemctl stop kubelet
sudo systemctl stop docker
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/lib/kubelet/*
sudo rm -rf /etc/cni/10-flannel.*
sudo rm -rf /etc/cni/10-flannel-*
sudo ifconfig cni0 down
sudo ifconfig flannel.1 down
sudo ifconfig docker0 down
sudo ip link set cni0 down
sudo ip link set flannel.1 down
sudo ip link delete cni0
sudo ip link delete flannel.1
sudo brctl delbr cni0
sudo brctl delbr flannel.1
EOF

cat <<'EOF' > ./scripts/show-crt-hash.sh
#!/bin/bash

if test ! "$(hostname)" = master0; then
  echo "error: do not use this script in nodes except master0"
  exit 1
fi

openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey \
  | openssl rsa -pubin -outform der \
  | openssl dgst -sha256 -hex
EOF

chmod +x ./scripts/*.sh


if test "$(hostname)" = master0; then
  ./scripts/kubeadm-init-master0.sh > kubeadm-init-out.log 2> kubeadm-init-err.log
fi

echo "$(date): all ok" >> ./ok

}
END_OF_INIT

chown work:work /home/work/init.sh
chmod +x /home/work/init.sh

sudo -u work /bin/bash /home/work/init.sh > /home/work/init-out.log 2> /home/work/init-err.log
