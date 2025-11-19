# Firewall Setup Script for Ubuntu

This script is designed to configure the firewall on an Ubuntu server using `UFW` (Uncomplicated Firewall). It allows **all incoming and outgoing traffic by default** but **blocks specific ports** that are considered unnecessary or unsafe. This helps in securing your server while keeping the required services accessible.

## Features

- **Update the system**: Ensures your system is up to date before configuring the firewall.
- **Install `UFW`**: Installs the Uncomplicated Firewall (UFW) if it is not already installed.
- **Allow all traffic by default**: Ensures all incoming and outgoing connections are allowed initially.
- **Block unnecessary and dangerous ports**:
  - **Email ports** (e.g., SMTP, POP3, IMAP)
  - **Database ports** (e.g., MySQL, PostgreSQL)
  - **Old and insecure protocols** (e.g., Telnet, TFTP)
  - **File-sharing ports** (e.g., FTP, SMB)
- **Enable `UFW`**: Activates UFW with the specified configuration.

## Prerequisites

- Ubuntu server 20.x or similar
- `sudo` privileges
- Access to the terminal

## How to Use

1. **Clone the repository** or **download the script**:

    ```bash
    git clone https://github.com/your-username/firewall-setup.git
    cd firewall-setup
    ```

2. **Make the script executable**:

    ```bash
    chmod +x setup-firewall.sh
    ```

3. **Run the script**:

    ```bash
    sudo ./setup-firewall.sh
    ```

4. The script will:
   - Update your system
   - Install UFW if it's not already installed
   - Allow all traffic by default and block unnecessary ports
   - Enable the UFW firewall with the new rules

5. **Verify UFW status**:

    After the script finishes, you can check the status of UFW with:

    ```bash
    sudo ufw status verbose
    ```

## Customizing the Script

- If you want to allow or block other ports, simply edit the script before running it. You can add additional `sudo ufw allow` or `sudo ufw deny` lines for other ports.

## License

This project is licensed under the MIT License.
