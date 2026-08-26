# ==============================================================================
# FILE: networking.tf — VCN baseline for the OpenClaw workstation
# ------------------------------------------------------------------------------
# ONE SUBNET, DELIBERATELY.
#
# Everything this project runs lives on a single instance, and that instance
# needs inbound RDP. The Packer builder also needs inbound SSH, and lands in the
# same subnet. There is no second workload, no second tier, and nothing that
# wants to be unreachable — so there is nothing for a private subnet to hold.
#
# This started as a port of aws-openclaw's four-subnet layout (two public, two
# private) plus a NAT gateway. That shape earns its keep on AWS, where the
# design spans availability zones and runs private workloads. Here it produced
# three subnets with nothing in them and a NAT gateway routing for nobody —
# billable infrastructure serving a refactor that was never planned.
#
# If this ever does move to a bastion topology, add the private subnet then.
# Carrying it speculatively cost real money and explained nothing.
#
# OCI difference worth knowing: security lists attach to the SUBNET, not the
# instance. Per-instance rules are NSGs, which 03-openclaw uses for RDP. Both
# are evaluated, and traffic must be permitted by both.
# ==============================================================================

# ==============================================================================
# SECTION: VCN
# ==============================================================================

resource "oci_core_vcn" "clawd_vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/24"
  display_name   = var.vcn_name

  # dns_label must be alphanumeric and <= 15 characters.
  dns_label = "clawdvcn"
}

# ==============================================================================
# SECTION: Internet Gateway
# ==============================================================================

resource "oci_core_internet_gateway" "clawd_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.clawd_vcn.id
  display_name   = "clawd-igw"
  enabled        = true
}

# ==============================================================================
# SECTION: Route Table
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

# ==============================================================================
# SECTION: Security List
# ------------------------------------------------------------------------------
# Lab defaults: SSH for the Packer builder, RDP for the desktop. Egress is wide
# open because LiteLLM calls the regional Gen AI endpoint and the desktop pulls
# packages.
#
# Note this is only half the story — the OCI Ubuntu image also runs a host
# firewall that drops everything except SSH, which 03-openclaw's userdata.sh
# opens at first boot. Allowing a port here does not make it reachable.
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

# ==============================================================================
# SECTION: Subnet
# ------------------------------------------------------------------------------
# pub-subnet-1  10.0.0.0/24  the OpenClaw host and the Packer builder
# ==============================================================================

resource "oci_core_subnet" "pub_subnet_1" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.clawd_vcn.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "pub-subnet-1"
  dns_label         = "pubsubnet1"
  route_table_id    = oci_core_route_table.public_rt.id
  security_list_ids = [oci_core_security_list.pub_sl.id]
}
