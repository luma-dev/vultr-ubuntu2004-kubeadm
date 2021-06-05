variable "project_name" {
  type = string
}

variable "region" {
  type = string
}

variable "vultr_api_key" {
  type = string
}

variable "v4_subnet" {
  type    = string
  default = "10.25.139.0"
}

variable "v4_subnet_mask" {
  type    = number
  default = 24
}

variable "instances" {
  type = map(any)
  default = {
    master0 = {
      hostname = "master0"
      plan     = "vc2-2c-4gb"
    },
    worker0 = {
      hostname = "worker0"
      plan     = "vc2-1c-2gb"
    },
  }
}

variable "ssh_key_ids" {
  type = list(string)
}
