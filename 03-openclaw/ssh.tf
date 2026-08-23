# ==============================================================================
# FILE: ssh.tf — SSH access for debugging
# ------------------------------------------------------------------------------
# WHY THIS EXISTS AT ALL
#
# aws-openclaw has no SSH key anywhere: it reaches the box through SSM Session
# Manager, which needs no key and no open port. OCI's nearest equivalent is the
# managed Bastion service, and that only forwards to instances in a PRIVATE
# subnet — this host deliberately sits in a public one so RDP works without a
# tunnel. So there is no key-free shell path here, and the port left the
# instance with no way in at all when cloud-init failed.
#
# That is exactly when you need a shell most, so the key is generated
# unconditionally rather than behind a "debug" toggle.
#
# The private key is written to ./keys/ with 0600 and is gitignored (*.pem).
# It is also in tfstate, like every other secret in this project.
#
# NOT the only way in. The serial console needs no key at all and works even
# when the network stack or the host firewall is broken:
#
#   oci compute instance-console-history capture --instance-id <ocid>
#   oci compute instance-console-history get-content \
#     --instance-console-history-id <id> --file -
#
# Every "NOTE:" line userdata.sh prints goes to /dev/console, so that command
# reproduces the whole boot log without logging in.
# ==============================================================================

# ==============================================================================
# SECTION: Key Generation
# ------------------------------------------------------------------------------
# RSA 4096 rather than ED25519: this key is pasted into instance metadata and
# read back by clients of unknown vintage, and RSA is the option nothing
# refuses. Nothing here is performance-sensitive.
# ==============================================================================

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/keys/openclaw_ssh.pem"
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "${path.module}/keys/openclaw_ssh.pub"
  file_permission = "0644"
}
