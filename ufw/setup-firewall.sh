#!/bin/bash

# Update the system
echo "Updating system..."
sudo apt update -y
sudo apt upgrade -y

# Install UFW (if not installed)
echo "Installing UFW..."
sudo apt install ufw -y

# Initial UFW setup: allow all incoming and outgoing traffic by default
echo "Allowing all incoming connections..."
sudo ufw default allow incoming
sudo ufw default allow outgoing

# Block unnecessary ports for security
echo "Blocking unnecessary ports..."

# Block email-related ports (SMTP, POP3, IMAP)
sudo ufw deny 25/tcp    # SMTP
sudo ufw deny 465/tcp   # SMTPS
sudo ufw deny 587/tcp   # SMTP Submission
sudo ufw deny 110/tcp   # POP3
sudo ufw deny 995/tcp   # POP3S
sudo ufw deny 143/tcp   # IMAP
sudo ufw deny 993/tcp   # IMAPS

# Block database-related ports (MySQL, PostgreSQL, etc.)
sudo ufw deny 3306/tcp  # MySQL
sudo ufw deny 5432/tcp  # PostgreSQL
sudo ufw deny 27017/tcp # MongoDB
sudo ufw deny 6379/tcp  # Redis
sudo ufw deny 11211/tcp # Memcached

# Block old/unsafe ports (Telnet, TFTP, etc.)
sudo ufw deny 23/tcp    # Telnet
sudo ufw deny 69/udp    # TFTP
sudo ufw deny 111/tcp   # RPC Portmapper
sudo ufw deny 515/tcp   # LPD Printer
sudo ufw deny 161/162/udp # SNMP
sudo ufw deny 5900/tcp  # VNC

# Block file-sharing ports (FTP, SMB, NFS)
sudo ufw deny 21/tcp    # FTP
sudo ufw deny 139/tcp   # SMB
sudo ufw deny 445/tcp   # SMB
sudo ufw deny 2049/tcp  # NFS

# Enable UFW with the new rules
echo "Enabling UFW..."
sudo ufw enable

# Display the final status of UFW
echo "UFW status:"
sudo ufw status verbose

echo "Firewall configuration complete."
