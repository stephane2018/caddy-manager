#!/bin/bash
set -euo pipefail

# Constants
CADDYFILE="/etc/caddy/Caddyfile"
DEFAULT_PROXY="127.0.0.1:8080"

# Check if Caddyfile exists
if [[ ! -f "$CADDYFILE" ]]; then
  echo "Error: Caddyfile not found at $CADDYFILE. Please verify your Caddy installation."
  exit 1
fi

# Function to ensure an email is configured in the global options block of the Caddyfile
ensure_email_configured() {
  # Check if email is already configured in Caddy
  if caddy environ | grep -q "email="; then
    echo "Email already configured in Caddy."
    return 0
  else
    # Email not configured, ask user to provide one
    echo "No email configured for Caddy. This is needed for HTTPS certificates."
    read -p "Please enter your email address: " email
    
    # Validate email format (basic validation)
    while [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
      echo "Invalid email format. Please try again."
      read -p "Please enter your email address: " email
    done
    
    # Set the email in Caddy
    caddy environ set email "$email"
    
    echo "Email configured successfully: $email"
    return 0
  fi
}

# Ensure an email is configured before proceeding
ensure_email_configured

# Display usage information for non-interactive mode
usage() {
    cat << EOF
Usage: $0 [options]

Options:
  -a, --add-domain DOMAIN [REDIRECT]
        Add a domain. Optionally specify a REDIRECT URL.
        If REDIRECT is omitted, the domain will use the default reverse proxy ($DEFAULT_PROXY).

  -s, --add-subdomain DOMAIN SUBDOMAIN [REDIRECT]
        Add a subdomain (as SUBDOMAIN.DOMAIN).
        Optionally specify a REDIRECT URL. If omitted, the default reverse proxy ($DEFAULT_PROXY) is used.

  -e, --edit-config TARGET
        Edit the configuration block for the specified domain or subdomain.
        The current configuration will be displayed for confirmation before editing.

  -r, --reload
        Reload the Caddy configuration.

  -h, --help
        Show this help message.

Examples:
  Add a domain with reverse proxy:
    $0 --add-domain example.com

  Add a domain with redirection:
    $0 --add-domain example.com https://newurl.com

  Add a subdomain:
    $0 --add-subdomain example.com blog

  Edit a configuration:
    $0 --edit-config example.com

  Reload Caddy configuration:
    $0 --reload

If no options are provided, an interactive menu will be launched.
EOF
}

# Function to add a domain
add_domain() {
    local domain="$1"
    local redirect="${2:-}"

    echo "Adding domain: $domain"

    if grep -q "^\s*${domain}\s*{" "$CADDYFILE"; then
        echo "Error: Domain '$domain' already exists in the Caddyfile."
        echo "Current configuration:"
        sed -n "/^\s*${domain}\s*{/,/^\s*}/p" "$CADDYFILE"
        return
    fi

    if [[ -z "$redirect" ]]; then
        sudo tee -a "$CADDYFILE" > /dev/null <<EOF

$domain {
    reverse_proxy $DEFAULT_PROXY
}
EOF
    else
        sudo tee -a "$CADDYFILE" > /dev/null <<EOF

$domain {
    redir $redirect
}
EOF
    fi

    echo "Domain '$domain' added successfully."
}

# Function to add a subdomain
add_subdomain() {
    local domain="$1"
    local subdomain="$2"
    local redirect="${3:-}"
    local full_domain="${subdomain}.${domain}"

    echo "Adding subdomain: $full_domain"

    if grep -q "^\s*${full_domain}\s*{" "$CADDYFILE"; then
        echo "Error: Subdomain '$full_domain' already exists in the Caddyfile."
        echo "Current configuration:"
        sed -n "/^\s*${full_domain}\s*{/,/^\s*}/p" "$CADDYFILE"
        return
    fi

    if [[ -z "$redirect" ]]; then
        sudo tee -a "$CADDYFILE" > /dev/null <<EOF

$full_domain {
    reverse_proxy $DEFAULT_PROXY
}
EOF
    else
        sudo tee -a "$CADDYFILE" > /dev/null <<EOF

$full_domain {
    redir $redirect
}
EOF
    fi

    echo "Subdomain '$full_domain' added successfully."
}

# Function to reload Caddy configuration
reload_caddy() {
    echo "Reloading Caddy configuration..."
    sudo systemctl reload caddy
    echo "Caddy reloaded successfully."
}

# Function to list current domain/subdomain configurations
list_config() {
    echo "Current Caddy configuration blocks:"
    grep -E '^[^#[:space:]].*\s*\{' "$CADDYFILE" || echo "No configuration blocks found."
}

# Function to create a backup of the Caddyfile
backup_config() {
    local backup_file="${CADDYFILE}.$(date +%Y%m%d%H%M%S).bak"
    sudo cp "$CADDYFILE" "$backup_file"
    echo "Backup created at: $backup_file"
}

# Function to validate the Caddy configuration
validate_config() {
    echo "Validating Caddy configuration..."
    if caddy validate --config "$CADDYFILE"; then
        echo "Configuration is valid."
    else
        echo "Configuration errors detected."
    fi
}

# Function to remove a configuration block for a given domain/subdomain
remove_config() {
    read -rp "Enter the domain or subdomain to remove (e.g., example.com or blog.example.com): " target

    backup_config

    sudo sed -i.bak "/^\s*${target}\s*{/,/^\s*}/d" "$CADDYFILE"
    echo "Configuration for '$target' removed. A backup of the original file is saved as ${CADDYFILE}.bak."
}

# Function to edit an existing configuration block
edit_config() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        read -rp "Enter the domain or subdomain to edit (e.g., example.com or blog.example.com): " target
    fi

    if ! grep -q "^\s*${target}\s*{" "$CADDYFILE"; then
        echo "Error: Configuration for '$target' does not exist."
        return
    fi

    echo "Current configuration for '$target':"
    sed -n "/^\s*${target}\s*{/,/^\s*}/p" "$CADDYFILE"

    read -rp "Do you want to modify this block? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Edit cancelled."
        return
    fi

    echo "Choose configuration type:"
    echo "1) Reverse Proxy (default: $DEFAULT_PROXY)"
    echo "2) Redirection"
    read -rp "Option (1/2): " config_option

    local new_block
    if [[ "$config_option" == "1" ]]; then
        read -rp "Enter reverse proxy address (default: $DEFAULT_PROXY): " new_proxy
        new_proxy=${new_proxy:-$DEFAULT_PROXY}
        new_block="${target} {\n    reverse_proxy ${new_proxy}\n}"
    elif [[ "$config_option" == "2" ]]; then
        read -rp "Enter redirection URL: " new_redirect
        new_block="${target} {\n    redir ${new_redirect}\n}"
    else
        echo "Invalid option, aborting edit."
        return
    fi

    backup_config

    sudo sed -i.bak "/^\s*${target}\s*{/,/^\s*}/d" "$CADDYFILE"
    echo -e "\n${new_block}" | sudo tee -a "$CADDYFILE" > /dev/null
    echo "Configuration for '$target' updated successfully."
    reload_caddy
}

# Interactive menu with additional features
interactive_menu() {
  while true; do
    echo ""
    echo "What would you like to do?"
    echo "1) Add a domain"
    echo "2) Add a subdomain"
    echo "3) List configuration"
    echo "4) Remove a configuration"
    echo "5) Backup configuration"
    echo "6) Validate configuration"
    echo "7) Reload Caddy"
    echo "8) Edit a configuration"
    echo "9) Exit"
    read -rp "Choose an option: " option

    case $option in
      1)
        read -rp "Enter the domain name (e.g., example.com): " domain
        read -rp "Enter the redirect URL (leave empty for local proxy): " redirect
        add_domain "$domain" "$redirect"
        reload_caddy
        ;;
      2)
        read -rp "Enter the main domain (e.g., example.com): " domain
        read -rp "Enter the subdomain (e.g., blog): " subdomain
        read -rp "Enter the redirect URL (leave empty for local proxy): " redirect
        add_subdomain "$domain" "$subdomain" "$redirect"
        reload_caddy
        ;;
      3)
        list_config
        ;;
      4)
        remove_config
        reload_caddy
        ;;
      5)
        backup_config
        ;;
      6)
        validate_config
        ;;
      7)
        reload_caddy
        ;;
      8)
        edit_config
        ;;
      9)
        echo "Exiting..."
        exit 0
        ;;
      *)
        echo "Invalid option. Please choose a valid option."
        ;;
    esac
  done
}

# Main: use non-interactive mode if arguments are provided; otherwise, launch interactive menu
if [[ $# -eq 0 ]]; then
    interactive_menu
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--add-domain)
                if [[ $# -lt 2 ]]; then
                    echo "Error: Missing domain argument."
                    usage
                    exit 1
                fi
                domain="$2"
                shift 2
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    redirect="$1"
                    shift
                else
                    redirect=""
                fi
                add_domain "$domain" "$redirect"
                reload_caddy
                ;;
            -s|--add-subdomain)
                if [[ $# -lt 3 ]]; then
                    echo "Error: Missing domain and subdomain arguments."
                    usage
                    exit 1
                fi
                domain="$2"
                subdomain="$3"
                shift 3
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    redirect="$1"
                    shift
                else
                    redirect=""
                fi
                add_subdomain "$domain" "$subdomain" "$redirect"
                reload_caddy
                ;;
            -e|--edit-config)
                if [[ $# -lt 2 ]]; then
                    echo "Error: Missing domain/subdomain argument for editing."
                    usage
                    exit 1
                fi
                target="$2"
                shift 2
                edit_config "$target"
                ;;
            -r|--reload)
                reload_caddy
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
fi
