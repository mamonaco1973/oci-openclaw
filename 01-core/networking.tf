# ==============================================================================
# FILE: networking.tf — VCN baseline for the OpenClaw workstation
# ------------------------------------------------------------------------------
# Mirrors the aws-openclaw layout: two public subnets and two private subnets
# in a /23, IGW for public egress, NAT for private egress.
#
# The OpenClaw host and the Packer build instance both land in pub-subnet-1.
# That is deliberate and matches AWS: the host needs inbound 3389 for RDP and
# the builder needs inbound SSH. The private subnets exist so the design can be
# tightened to a bastion-only topology without re-cutting the address plan.
#
# OCI difference worth knowing: security lists attach to the SUBNET, not to the
# instance. Per-instance rules are NSGs, which 03-openclaw uses for RDP. Both
# are evaluated, and traffic must be permitted by both.
# ==============================================================================

# ==============================================================================
# VCN
# ==============================================================================

resource "oci_core_vcn" "clawd_vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/23"
  display_name   = var.vcn_name

  # dns_label must be alphanumeric and <= 15 characters.
  dns_label = "clawdvcn"
}

# ==============================================================================
# Gateways
# ==============================================================================

resource "oci_core_internet_gateway" "clawd_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "clawd-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "clawd_nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "clawd-nat"
}

# ==============================================================================
# Route Tables
# ==============================================================================

resource "oci_core_route_table" "public_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "public-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.clawd_igw.id
  }
}

resource "oci_core_route_table" "private_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "private-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.clawd_nat.id
  }
}

# ==============================================================================
# Security Lists
# ------------------------------------------------------------------------------
# Lab defaults: SSH for the Packer builder, RDP for the desktop. Egress is wide
# open because LiteLLM calls the Gen AI endpoint and the desktop pulls packages.
# ==============================================================================

resource "oci_core_security_list" "pub_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "pub-security-list"

  # SSH — Packer connects to the temporary build instance over the internet.
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # RDP — the OpenClaw desktop.
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 3389
      max = 3389
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

resource "oci_core_security_list" "vm_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "vm-security-list"

  ingress_security_rules {
    protocol  = "all"
    source    = "10.0.0.0/23"
    stateless = false
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# ==============================================================================
# Subnets
# ------------------------------------------------------------------------------
#   pub-subnet-1  10.0.0.0/26    OpenClaw host + Packer builder (IGW)
#   pub-subnet-2  10.0.0.64/26   spare public capacity (IGW)
#   vm-subnet-1   10.0.0.128/26  private workload (NAT)
#   vm-subnet-2   10.0.0.192/26  private workload (NAT)
# ==============================================================================

resource "oci_core_subnet" "pub_subnet_1" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.clawd_vcn.id
  cidr_block        = "10.0.0.0/26"
  display_name      = "pub-subnet-1"
  dns_label         = "pubsubnet1"
  route_table_id    = oci_core_route_table.public_rt.id
  security_list_ids = [oci_core_security_list.pub_sl.id]
}

resource "oci_core_subnet" "pub_subnet_2" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.clawd_vcn.id
  cidr_block        = "10.0.0.64/26"
  display_name      = "pub-subnet-2"
  dns_label         = "pubsubnet2"
  route_table_id    = oci_core_route_table.public_rt.id
  security_list_ids = [oci_core_security_list.pub_sl.id]
}

resource "oci_core_subnet" "vm_subnet_1" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.clawd_vcn.id
  cidr_block                 = "10.0.0.128/26"
  display_name               = "vm-subnet-1"
  dns_label                  = "vmsubnet1"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private_rt.id
  security_list_ids          = [oci_core_security_list.vm_sl.id]
}

resource "oci_core_subnet" "vm_subnet_2" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.clawd_vcn.id
  cidr_block                 = "10.0.0.192/26"
  display_name               = "vm-subnet-2"
  dns_label                  = "vmsubnet2"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private_rt.id
  security_list_ids          = [oci_core_security_list.vm_sl.id]
}
