terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "2.3.0"
    }
  }
}

provider "vultr" {
  api_key     = var.vultr_api_key
  rate_limit  = 700
  retry_limit = 3
}

resource "vultr_firewall_group" "fw" {
  description = var.project_name
}

resource "vultr_firewall_rule" "fw_allow_ssh_v4" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
  notes             = "allow ssh ipv4 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_ssh_v6" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "22"
  notes             = "allow ssh ipv6 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_wireguard_v4" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "51820"
  notes             = "allow wireguard ipv4 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_wireguard_v6" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "51820"
  notes             = "allow wireguard ipv6 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_icmp_v4" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "icmp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  notes             = "allow icmp ipv4 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_icmp_v6" {
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = "icmp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  notes             = "allow icmp ipv6 from anywhere"
}

resource "vultr_firewall_rule" "fw_allow_all_internal" {
  for_each = {
    for key, value in flatten([
      for instances_key in keys(var.instances) : [
        for protocol in ["icmp", "tcp", "udp"] : [
          for ip_type in ["v4", "v6"] : [
            {
              protocol    = protocol
              ip_type     = ip_type
              port        = protocol == "tcp" || protocol == "udp" ? "1:65535" : null
              subnet      = ip_type == "v4" ? vultr_instance.hosts[instances_key].main_ip : vultr_instance.hosts[instances_key].v6_main_ip
              subnet_size = ip_type == "v4" ? 32 : 128
            },
          ]
        ]
      ]
    ]) : key => value
  }
  firewall_group_id = vultr_firewall_group.fw.id
  protocol          = each.value.protocol
  ip_type           = each.value.ip_type
  port              = each.value.port
  subnet            = each.value.subnet
  subnet_size       = each.value.subnet_size
  notes             = "allow all ${each.value.ip_type} internal ${each.value.protocol} traffics from ${each.value.subnet}"
}

resource "vultr_private_network" "private_network" {
  description    = var.project_name
  v4_subnet      = var.v4_subnet
  v4_subnet_mask = var.v4_subnet_mask
  region         = var.region
}

resource "vultr_startup_script" "setup_ubuntu2004" {
  name   = "setup-ubuntu2004"
  script = filebase64("files/setup_ubuntu2004.sh")
}

resource "vultr_instance" "hosts" {
  for_each          = var.instances
  backups           = "disabled"
  hostname          = each.value.hostname
  enable_ipv6       = true
  firewall_group_id = vultr_firewall_group.fw.id
  private_network_ids = [
    vultr_private_network.private_network.id,
  ]
  ssh_key_ids = var.ssh_key_ids
  script_id   = vultr_startup_script.setup_ubuntu2004.id
  region      = var.region
  os_id       = "387"
  plan        = each.value.plan
}

output "host_v4_list" {
  value = {
    for key in keys(var.instances)
    : key => vultr_instance.hosts[key].main_ip
  }
}

output "host_v6_list" {
  value = {
    for key in keys(var.instances)
    : key => vultr_instance.hosts[key].v6_main_ip
  }
}
