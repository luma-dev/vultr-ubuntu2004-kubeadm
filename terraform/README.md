# luma-vpn-planet-infrastructure

Build your own Kubernetes on Vultr Cloud Instances.

## Credits

- Kubernetes
- Kubeadm
- Vultr
- Terraform
- Calico

## Features

- Support IPv4/IPv6 dual-stack
- Support multiple master/worker nodes.

## Usage

Warning:
  **No warranty** for any usage of this project contents. Please refer to them at your own risk.
  I strongly recommend to use Cloud Providers' fully controlled Kubernetes services like AWS EKS, Google Cloud GKE or Azure Kubernetes Service for production-level purpose, and enterprise development/education purpose as well.

### 1. Prepare Terraform backend

I recommend use Terraform Cloud.

### 2. Prepare your Vultr account API key

Go to your account settings and make one. Then set it as terraform variable.

### 3. Supply others parameters

Please refer [variables.tf](./variables.tf).

### 4. Apply terraform definitions

```
# on local machine, in <project-root>/terraform
terraform apply
```

### 5. Setup environment variables to make working easy

```
# on local machine, in <project-root>/terraform

# bash/zsh
source <root>/scripts/activate.sh

# fish
source <root>/scripts/activate.fish
```

After that you can use environment variables like `$master0`, `$worker0` as public IPv4 addresses.

### 6. SSH into primary master node (master0)

```
# on local machine
ssh work@$master0
work@master0$ stat ok  # please wait for ./ok file created
work@master0$ cat ./kubeadm-init-out.log
```

- Copy `kubeadm join --token ... --control-plane --certificate-key ...` for control planes.
- Copy `kubeadm join --token ...` for worker nodes.

# 7. SSH into others instances and join

```
ssh work@$master1
work@master1$ ./scripts/kubeadm-join-control-plane.sh <paste here copied "kubeadm --token ... --certificate-key ..." command>

ssh work@$worker0
work@worker0$ ./scripts/kubeadm-join-worker.sh <paste here copied "kubeadm --token ..." command>
```

I recommend adding one by one. Keep checking status by `watch kubectl get nodes` on primary control plane.

Also keep in mind that the initial token is valid only for first 24 hours and certificate key is valid for first 2 hours.

If you want to send certificate keys by yourself, please comment out `--upload-certs` and `scp` by yourself or you can use [script/setup_ha_master](./scripts/setup_ha_master.sh) on local machine.

# 8. All done!

Your self-hosted Kubernetes cluster up now in your hands!
