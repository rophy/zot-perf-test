variable "region" { default = "us-east-1" }
variable "az" { default = "us-east-1a" }
variable "zot_instance_type" { default = "m6idn.2xlarge" }
variable "client_instance_type" { default = "m6idn.2xlarge" }
# zot storage: a dedicated gp3 volume (persists across stop/start, unlike instance-store NVMe).
variable "zot_data_volume_size" { default = 100 }
variable "zot_data_volume_iops" { default = 3000 }
variable "zot_data_volume_throughput" { default = 125 }
variable "zot_version" { default = "v2.1.21" }
variable "k6_version" { default = "v2.3.0" }
variable "prometheus_version" { default = "3.15.0" }
variable "node_exporter_version" { default = "1.12.1" }
variable "crane_version" { default = "v0.22.1" }
variable "operator_cidr" {
  description = "CIDR allowed to SSH. Empty = auto-detect current public IP /32."
  default     = ""
}
