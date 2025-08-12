#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    # Check if $3 exists, otherwise set to empty string
    local nonewline=${3:-""}
    
    if [ "$nonewline" = "nonewline" ]; then
        echo -en "${2}${1}${NC}"
    else
        echo -e "${2}${1}${NC}"
    fi
}

# ASCII Art Banner
cat << "EOF"
 ____  _         _ _   _ _____ _____    ____      
| __ )(_)_ __ __| | \ | | ____|_   _|  / ___| ___ 
|  _ \| | '__/ _` |  \| |  _|   | |   | |  _ / _ \
| |_) | | | | (_| | |\  | |___  | |   | |_| | (_) |
|____/|_|_|  \__,_|_| \_|_____| |_|    \____|\___/ 
EOF

print_message "\n🐦 BirdNET-Go Installation Script" "$GREEN"
print_message "This script will install BirdNET-Go and its dependencies." "$YELLOW"

BIRDNET_GO_VERSION="nightly"
BIRDNET_GO_IMAGE="ghcr.io/tphakala/birdnet-go:${BIRDNET_GO_VERSION}"

# Function to get IP address
get_ip_address() {
    # Get primary IP address, excluding docker and localhost interfaces
    local ip=""
    
    # Method 1: Try using ip command with POSIX-compatible regex
    if command_exists ip; then
        ip=$(ip -4 addr show scope global \
          | grep -vE 'docker|br-|veth' \
          | grep -oE 'inet ([0-9]+\.){3}[0-9]+' \
          | awk '{print $2}' \
          | head -n1)
    fi
    
    # Method 2: Try hostname command for fallback if ip command didn't work
    if [ -z "$ip" ] && command_exists hostname; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # Method 3: Try ifconfig as last resort
    if [ -z "$ip" ] && command_exists ifconfig; then
        ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1 | awk '{print $2}' | sed 's/addr://')
    fi
    
    # Return the IP address or empty string
    echo "$ip"
}

# Function to check if mDNS is available
check_mdns() {
    # First check if avahi-daemon is installed
    if ! command_exists avahi-daemon && ! command_exists systemctl; then
        return 1
    fi

    # Then check if it's running
    if command_exists systemctl && systemctl is-active --quiet avahi-daemon; then
        hostname -f | grep -q ".local"
        return $?
    fi
    return 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if curl is available and install it if needed
ensure_curl() {
    if ! command_exists curl; then
        print_message "📦 curl not found. Installing curl..." "$YELLOW"
        if sudo apt -qq update && sudo apt install -qq -y curl; then
            print_message "✅ curl installed successfully" "$GREEN"
        else
            print_message "❌ Failed to install curl" "$RED"
            print_message "Please install curl manually and try again" "$YELLOW"
            exit 1
        fi
    fi
}

# Function to check network connectivity
check_network() {
    print_message "🌐 Checking network connectivity..." "$YELLOW"
    local success=true

    # First do a basic ping test to check general connectivity
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        send_telemetry_event "error" "Network connectivity failed" "error" "step=network_check,error=ping_failed"
        print_message "❌ No network connectivity (ping test failed)" "$RED"
        print_message "Please check your internet connection and try again" "$YELLOW"
        exit 1
    fi

    # Now ensure curl is available for further tests
    ensure_curl
     
    # HTTP/HTTPS Check
    print_message "\n📡 Testing HTTP/HTTPS connectivity..." "$YELLOW"
    local urls=(
        "https://github.com"
        "https://raw.githubusercontent.com"
        "https://ghcr.io"
    )
    
    for url in "${urls[@]}"; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url")
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            print_message "✅ HTTPS connection successful to $url (HTTP $http_code)" "$GREEN"
        else
            print_message "❌ HTTPS connection failed to $url (HTTP $http_code)" "$RED"
            success=false
        fi
    done

    # Docker Registry Check
    print_message "\n📡 Testing GitHub registry connectivity..." "$YELLOW"
    if curl -s "https://ghcr.io/v2/" >/dev/null 2>&1; then
        print_message "✅ GitHub registry is accessible" "$GREEN"
    else
        print_message "❌ Cannot access Docker registry" "$RED"
        success=false
    fi

    if [ "$success" = false ]; then
        print_message "\n❌ Network connectivity check failed" "$RED"
        print_message "Please check:" "$YELLOW"
        print_message "  • Internet connection" "$YELLOW"
        print_message "  • DNS settings (/etc/resolv.conf)" "$YELLOW"
        print_message "  • Firewall rules" "$YELLOW"
        print_message "  • Proxy settings (if applicable)" "$YELLOW"
        return 1
    fi

    print_message "\n✅ Network connectivity check passed\n" "$GREEN"
    return 0
}

# Function to check system prerequisites
check_prerequisites() {
    print_message "🔧 Checking system prerequisites..." "$YELLOW"

    # Check CPU architecture and generation
    case "$(uname -m)" in
        "x86_64")
            # Check CPU flags for AVX2 (Haswell and newer)
            if ! grep -q "avx2" /proc/cpuinfo; then
                send_telemetry_event "error" "CPU requirements not met" "error" "step=check_prerequisites,error=no_avx2"
                print_message "❌ Your Intel CPU is too old. BirdNET-Go requires Intel Haswell (2013) or newer CPU with AVX2 support" "$RED"
                exit 1
            else
                print_message "✅ Intel CPU architecture and generation check passed" "$GREEN"
            fi
            ;;
        "aarch64"|"arm64")
            print_message "✅ ARM 64-bit architecture detected, continuing with installation" "$GREEN"
            ;;
        "armv7l"|"armv6l"|"arm")
            send_telemetry_event "error" "Architecture requirements not met" "error" "step=check_prerequisites,error=32bit_arm"
            print_message "❌ 32-bit ARM architecture detected. BirdNET-Go requires 64-bit ARM processor and OS" "$RED"
            exit 1
            ;;
        *)
            send_telemetry_event "error" "Unsupported CPU architecture" "error" "step=check_prerequisites,error=unsupported_arch,arch=$(uname -m)"
            print_message "❌ Unsupported CPU architecture: $(uname -m)" "$RED"
            exit 1
            ;;
    esac

    # shellcheck source=/etc/os-release
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        print_message "❌ Cannot determine OS version" "$RED"
        exit 1
    fi

    # Check for supported distributions
    case "$ID" in
        debian)
            # Debian 11 (Bullseye) has VERSION_ID="11"
            if [ -n "$VERSION_ID" ] && [ "$VERSION_ID" -lt 11 ]; then
                print_message "❌ Debian $VERSION_ID too old. Version 11 (Bullseye) or newer required" "$RED"
                exit 1
            else
                print_message "✅ Debian $VERSION_ID found" "$GREEN"
            fi
            ;;
        raspbian)
            print_message "❌ You are running 32-bit version of Raspberry Pi OS. BirdNET-Go requires 64-bit version" "$RED"
            exit 1
            ;;
        ubuntu)
            # Ubuntu 20.04 has VERSION_ID="20.04"
            ubuntu_version=$(echo "$VERSION_ID" | awk -F. '{print $1$2}')
            if [ "$ubuntu_version" -lt 2004 ]; then
                print_message "❌ Ubuntu $VERSION_ID too old. Version 20.04 or newer required" "$RED"
                exit 1
            else
                print_message "✅ Ubuntu $VERSION_ID found" "$GREEN"
            fi
            ;;
        *)
            print_message "❌ Unsupported Linux distribution for install.sh. Please use Debian 11+, Ubuntu 20.04+, or Raspberry Pi OS (Bullseye+)" "$RED"
            exit 1
            ;;
    esac

    # Function to add user to required groups
    add_user_to_groups() {
        print_message "🔧 Adding user $USER to required groups..." "$YELLOW"
        local groups_added=false

        if ! groups "$USER" | grep &>/dev/null "\bdocker\b"; then
            if sudo usermod -aG docker "$USER"; then
                print_message "✅ Added user $USER to docker group" "$GREEN"
                groups_added=true
            else
                print_message "❌ Failed to add user $USER to docker group" "$RED"
                exit 1
            fi
        fi

        if ! groups "$USER" | grep &>/dev/null "\baudio\b"; then
            if sudo usermod -aG audio "$USER"; then
                print_message "✅ Added user $USER to audio group" "$GREEN"
                groups_added=true
            else
                print_message "❌ Failed to add user $USER to audio group" "$RED"
                exit 1
            fi
        fi

        # Add user to adm group for journalctl access
        if ! groups "$USER" | grep &>/dev/null "\badm\b"; then
            if sudo usermod -aG adm "$USER"; then
                print_message "✅ Added user $USER to adm group" "$GREEN"
                groups_added=true
            else
                print_message "❌ Failed to add user $USER to adm group" "$RED"
                exit 1
            fi
        fi

        if [ "$groups_added" = true ]; then
            print_message "Please log out and log back in for group changes to take effect, and rerun install.sh to continue with install" "$YELLOW"
            exit 0
        fi
    }

    # Check and install Docker
    if ! command_exists docker; then
        print_message "🐳 Docker not found. Installing Docker..." "$YELLOW"
        # Install Docker from apt repository
        sudo apt -qq update
        sudo apt -qq install -y docker.io
        # Add current user to required groups
        add_user_to_groups
        # Start Docker service
        if sudo systemctl start docker; then
            print_message "✅ Docker service started successfully" "$GREEN"
        else
            print_message "❌ Failed to start Docker service" "$RED"
            exit 1
        fi
        
        # Enable Docker service on boot
        if  sudo systemctl enable docker; then
            print_message "✅ Docker service start on boot enabled successfully" "$GREEN"
        else
            print_message "❌ Failed to enable Docker service on boot" "$RED"
            exit 1
        fi
        print_message "⚠️ Docker installed successfully. To make group member changes take effect, please log out and log back in and rerun install.sh to continue with install" "$YELLOW"
        # exit install script
        exit 0
    else
        print_message "✅ Docker found" "$GREEN"
        
        # Check if user is in required groups
        add_user_to_groups

        # Check if Docker can be used by the user
        if ! docker info &>/dev/null; then
            print_message "❌ Docker cannot be accessed by user $USER. Please ensure you have the necessary permissions." "$RED"
            exit 1
        else
            print_message "✅ Docker is accessible by user $USER" "$GREEN"
        fi
    fi

    print_message "🥳 System prerequisites checks passed" "$GREEN"
    print_message ""
}

# Function to check if systemd is the init system
check_systemd() {
    if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
        print_message "❌ This script requires systemd as the init system" "$RED"
        print_message "Your system appears to be using: $(ps -p 1 -o comm=)" "$YELLOW"
        exit 1
    else
        print_message "✅ Systemd detected as init system" "$GREEN"
    fi
}

# Function to check if a directory exists
check_directory_exists() {
    local dir="$1"
    if [ -d "$dir" ]; then
        return 0 # Directory exists
    else
        return 1 # Directory does not exist
    fi
}

# Function to check if directories can be created
check_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        if ! mkdir -p "$dir" 2>/dev/null; then
            print_message "❌ Cannot create directory $dir" "$RED"
            print_message "Please check permissions" "$YELLOW"
            exit 1
        fi
    elif [ ! -w "$dir" ]; then
        print_message "❌ Cannot write to directory $dir" "$RED"
        print_message "Please check permissions" "$YELLOW"
        exit 1
    fi
}

# Telemetry Configuration
TELEMETRY_ENABLED=false
TELEMETRY_INSTALL_ID=""
SENTRY_DSN="https://b9269b6c0f8fae154df65be5a97e0435@o4509553065525248.ingest.de.sentry.io/4509553112186960"

# Function to generate anonymous install ID
generate_install_id() {
    # Generate a UUID-like ID using /dev/urandom
    local id=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -x -An | tr -d ' \n' | cut -c1-32)
    # Format as UUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    echo "${id:0:8}-${id:8:4}-${id:12:4}-${id:16:4}-${id:20:12}"
}

# Function to load or create telemetry config
load_telemetry_config() {
    local telemetry_file="$CONFIG_DIR/.telemetry"
    
    if [ -f "$telemetry_file" ]; then
        # Load existing config
        TELEMETRY_ENABLED=$(grep "^enabled=" "$telemetry_file" 2>/dev/null | cut -d'=' -f2 || echo "false")
        TELEMETRY_INSTALL_ID=$(grep "^install_id=" "$telemetry_file" 2>/dev/null | cut -d'=' -f2 || echo "")
    fi
    
    # Generate install ID if missing
    if [ -z "$TELEMETRY_INSTALL_ID" ]; then
        TELEMETRY_INSTALL_ID=$(generate_install_id)
    fi
}

# Function to save telemetry config
save_telemetry_config() {
    local telemetry_file="$CONFIG_DIR/.telemetry"
    
    # Ensure directory exists
    mkdir -p "$CONFIG_DIR"
    
    # Save config
    cat > "$telemetry_file" << EOF
# BirdNET-Go telemetry configuration
# This file stores your telemetry preferences
enabled=$TELEMETRY_ENABLED
install_id=$TELEMETRY_INSTALL_ID
EOF
}

# Function to configure telemetry
configure_telemetry() {
    print_message "\n📊 Telemetry Configuration" "$GREEN"
    print_message "BirdNET-Go can send anonymous usage data to help improve the software." "$YELLOW"
    print_message "This includes:" "$YELLOW"
    print_message "  • Installation success/failure events" "$YELLOW"
    print_message "  • Anonymous system information (OS, architecture)" "$YELLOW"  
    print_message "  • Error diagnostics (no personal data)" "$YELLOW"
    print_message "\nNo audio data or bird detections are ever collected." "$GREEN"
    print_message "You can disable this at any time in the web interface." "$GREEN"
    
    print_message "\n❓ Enable anonymous telemetry? (y/n): " "$YELLOW" "nonewline"
    read -r enable_telemetry
    
    if [[ $enable_telemetry == "y" ]]; then
        TELEMETRY_ENABLED=true
        print_message "✅ Telemetry enabled. Thank you for helping improve BirdNET-Go!" "$GREEN"
        
        # Update config.yaml to enable Sentry
        if [ -f "$CONFIG_FILE" ]; then
            sed -i 's/enabled: false  # true to enable Sentry error tracking/enabled: true  # true to enable Sentry error tracking/' "$CONFIG_FILE"
        fi
    else
        TELEMETRY_ENABLED=false
        print_message "✅ Telemetry disabled. You can enable it later in settings if you wish." "$GREEN"
    fi
    
    # Save telemetry config
    save_telemetry_config
}

# Function to collect anonymous system information
collect_system_info() {
    local os_name="unknown"
    local os_version="unknown"
    local cpu_arch=$(uname -m)
    local docker_version="unknown"
    local pi_model="none"
    
    # Read OS information from /etc/os-release
    if [ -f /etc/os-release ]; then
        # Source the file to get the variables
        . /etc/os-release
        os_name="${ID:-unknown}"
        os_version="${VERSION_ID:-unknown}"
    fi
    
    # Get Docker version if available
    if command_exists docker; then
        docker_version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    fi
    
    # Detect Raspberry Pi model or WSL
    if [ -f /proc/device-tree/model ]; then
        pi_model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | sed 's/Raspberry Pi/RPi/g' || echo "none")
    elif grep -q microsoft /proc/version 2>/dev/null; then
        pi_model="wsl"
    fi
    
    # Output as JSON
    echo "{\"os_name\":\"$os_name\",\"os_version\":\"$os_version\",\"cpu_arch\":\"$cpu_arch\",\"docker_version\":\"$docker_version\",\"pi_model\":\"$pi_model\",\"install_id\":\"$TELEMETRY_INSTALL_ID\"}"
}

# Function to send telemetry event
send_telemetry_event() {
    # Check if telemetry is enabled
    if [ "$TELEMETRY_ENABLED" != "true" ]; then
        return 0
    fi
    
    local event_type="$1"
    local message="$2"
    local level="${3:-info}"
    local context="${4:-}"
    
    # Collect system info before background process
    local system_info
    system_info=$(collect_system_info)
    
    # Run in background to not block installation
    {
        
        # Build JSON payload
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local payload=$(cat <<EOF
{
    "timestamp": "$timestamp",
    "level": "$level",
    "message": "$message",
    "platform": "other",
    "environment": "production",
    "release": "install-script@1.0.0",
    "tags": {
        "event_type": "$event_type",
        "script_version": "1.0.0"
    },
    "contexts": {
        "os": {
            "name": "$(echo "$system_info" | jq -r .os_name)",
            "version": "$(echo "$system_info" | jq -r .os_version)"
        },
        "device": {
            "arch": "$(echo "$system_info" | jq -r .cpu_arch)",
            "model": "$(echo "$system_info" | jq -r .pi_model)"
        }
    },
    "extra": {
        "docker_version": "$(echo "$system_info" | jq -r .docker_version)",
        "install_id": "$(echo "$system_info" | jq -r .install_id)",
        "context": "$context"
    }
}
EOF
)
        
        # Extract DSN components
        local sentry_key=$(echo "$SENTRY_DSN" | grep -oE 'https://[a-f0-9]+' | sed 's/https:\/\///')
        local sentry_project=$(echo "$SENTRY_DSN" | grep -oE '[0-9]+$')
        local sentry_host=$(echo "$SENTRY_DSN" | grep -oE '@[^/]+' | sed 's/@//')
        
        # Send to Sentry (timeout after 5 seconds, silent failure)
        curl -s -m 5 \
            -X POST \
            "https://${sentry_host}/api/${sentry_project}/store/" \
            -H "Content-Type: application/json" \
            -H "X-Sentry-Auth: Sentry sentry_key=${sentry_key}, sentry_version=7" \
            -d "$payload" \
            >/dev/null 2>&1 || true
    } &
    
    # Return immediately
    return 0
}

# Function to check if there is enough disk space for Docker image
check_docker_space() {
    local required_space=2000000  # 2GB in KB
    local available_space
    available_space=$(df -k /var/lib/docker | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        print_message "❌ Insufficient disk space for Docker image" "$RED"
        print_message "Required: 2GB, Available: $((available_space/1024))MB" "$YELLOW"
        exit 1
    fi
}

# Function to pull Docker image
pull_docker_image() {
    print_message "\n🐳 Pulling BirdNET-Go Docker image from GitHub Container Registry..." "$YELLOW"
    
    # Check if Docker can be used by the user
    if ! docker info &>/dev/null; then
        print_message "❌ Docker cannot be accessed by user $USER. Please ensure you have the necessary permissions." "$RED"
        print_message "This could be due to:" "$YELLOW"
        print_message "- User $USER is not in the docker group" "$YELLOW"
        print_message "- Docker service is not running" "$YELLOW"
        print_message "- Insufficient privileges to access Docker socket" "$YELLOW"
        exit 1
    fi

    if docker pull "${BIRDNET_GO_IMAGE}"; then
        print_message "✅ Docker image pulled successfully" "$GREEN"
    else
        send_telemetry_event "error" "Docker image pull failed" "error" "step=pull_docker_image,image=${BIRDNET_GO_IMAGE}"
        print_message "❌ Failed to pull Docker image" "$RED"
        print_message "This could be due to:" "$YELLOW"
        print_message "- No internet connection" "$YELLOW"
        print_message "- GitHub container registry being unreachable" "$YELLOW"
        print_message "- Invalid image name or tag" "$YELLOW"
        print_message "- Insufficient privileges to access Docker socket on local system" "$YELLOW"
        exit 1
    fi
}

# Helper function to check if BirdNET-Go systemd service exists
detect_birdnet_service() {
    # Check for service unit files on disk
    if [ -f "/etc/systemd/system/birdnet-go.service" ] || [ -f "/lib/systemd/system/birdnet-go.service" ]; then
        return 0
    fi
    return 1
}

# Function to check if BirdNET service exists
check_service_exists() {
    detect_birdnet_service
    return $?
}

# Function to safely execute docker commands, suppressing errors if Docker isn't installed
safe_docker() {
    if command_exists docker; then
        docker "$@" 2>/dev/null
        return $?
    fi
    return 1
}

# Function to check if BirdNET-Go is fully installed (service + container)
check_birdnet_installation() {
    local service_exists=false
    local image_exists=false
    local container_exists=false
    local container_running=false
    local debug_output=""

    # Check for systemd service
    if detect_birdnet_service; then
        service_exists=true
        debug_output="${debug_output}Systemd service detected. "
    fi
    
    # Only check Docker components if Docker is installed
    if command_exists docker; then
        # Streamlined Docker checks
        # Check for BirdNET-Go images
        if safe_docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "birdnet-go"; then
            image_exists=true
            debug_output="${debug_output}Docker image exists. "
        fi
        
        # Check for any BirdNET-Go containers (running or stopped)
        container_count=$(safe_docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | wc -l)
        
        if [ "$container_count" -gt 0 ]; then
            container_exists=true
            debug_output="${debug_output}Container exists. "
            
            # Check if any of these containers are running
            running_count=$(safe_docker ps --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | wc -l)
            if [ "$running_count" -gt 0 ]; then
                container_running=true
                debug_output="${debug_output}Container running. "
            fi
        fi
        
        # Fallback check for containers with birdnet-go in the name
        if [ "$container_exists" = false ]; then
            if safe_docker ps -a | grep -q "birdnet-go"; then
                container_exists=true
                debug_output="${debug_output}Container with birdnet name exists. "
                
                # Check if any of these containers are running
                if safe_docker ps | grep -q "birdnet-go"; then
                    container_running=true
                    debug_output="${debug_output}Container with birdnet name running. "
                fi
            fi
        fi
    fi
    
    # Debug output - uncomment to debug installation check
    # print_message "DEBUG: $debug_output Service: $service_exists, Image: $image_exists, Container: $container_exists, Running: $container_running" "$YELLOW"
    
    # Check if Docker components exist (image or containers)
    local docker_components_exist
    if [ "$image_exists" = true ] || [ "$container_exists" = true ] || [ "$container_running" = true ]; then
        docker_components_exist=true
    else
        docker_components_exist=false
    fi    
    
    # Full installation: service AND Docker components
    if [ "$service_exists" = true ] && [ "$docker_components_exist" = true ]; then
        echo "full"  # Full installation with systemd
        return 0
    fi
    
    # Docker-only installation: Docker components but no service
    if [ "$service_exists" = false ] && [ "$docker_components_exist" = true ]; then
        echo "docker"  # Docker-only installation
        return 0
    fi
    
    echo "none"  # No installation
    return 1  # No installation
}

# Function to check if we have preserved data from previous installation
check_preserved_data() {
    if [ -f "$CONFIG_FILE" ] || [ -d "$DATA_DIR" ]; then
        return 0  # Preserved data exists
    fi
    return 1  # No preserved data
}

# Function to convert only relative paths to absolute paths
convert_relative_to_absolute_path() {
    local config_file=$1
    local abs_path=$2
    local export_section_line # Declare separately

    # Look specifically for the audio export path in the export section
    export_section_line=$(grep -n "export:" "$config_file" | cut -d: -f1) # Assign separately
    if [ -z "$export_section_line" ]; then
        print_message "⚠️ Export section not found in config file" "$YELLOW"
        return 1
    fi

    # Find the path line within the export section (looking only at the next few lines after export:)
    local clip_path_line # Declare separately
    clip_path_line=$(tail -n +$export_section_line "$config_file" | grep -n "path:" | head -1 | cut -d: -f1) # Assign separately
    if [ -z "$clip_path_line" ]; then
        print_message "⚠️ Clip path setting not found in export section" "$YELLOW"
        return 1
    fi

    # Calculate the actual line number in the file
    clip_path_line=$((export_section_line + clip_path_line - 1))

    # Extract the current path value
    local current_path # Declare separately
    # Corrected sed command and assignment
    current_path=$(sed -n "${clip_path_line}s/^[[:space:]]*path:[[:space:]]*\([^#]*\).*/\1/p" "$config_file" | xargs)

    # Remove quotes if present
    current_path=${current_path#\"}
    current_path=${current_path%\"}

    # Only convert if path is relative (doesn't start with /)
    if [[ ! "$current_path" =~ ^/ ]]; then
        print_message "Converting relative path '${current_path}' to absolute path '${abs_path}'" "$YELLOW"
        # Use line-specific sed to replace just the clips path line
        # Corrected sed command for replacement
        sed -i "${clip_path_line}s|^\([[:space:]]*path:[[:space:]]*\).*|\1${abs_path}        # path to audio clip export directory|" "$config_file"
        return 0
    else
        print_message "Path '${current_path}' is already absolute, skipping conversion" "$GREEN"
        return 1
    fi
}

# Function to handle all path migrations
update_paths_in_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_message "🔧 Updating paths in configuration file..." "$YELLOW"
        if convert_relative_to_absolute_path "$CONFIG_FILE" "/data/clips/"; then
            print_message "✅ Audio export path updated to absolute path" "$GREEN"
        else
            print_message "ℹ️ Audio export path already absolute; no changes made" "$YELLOW"
        fi
    fi
}

# Helper function to clean up HLS tmpfs mount
cleanup_hls_mount() {
    local hls_mount="${CONFIG_DIR}/hls"
    local mount_unit # Declare separately
    mount_unit=$(systemctl list-units --type=mount | grep -i "$hls_mount" | awk '{print $1}') # Assign separately
    
    print_message "🧹 Cleaning up tmpfs mounts..." "$YELLOW"
    
    # First check if the mount exists
    if mount | grep -q "$hls_mount" || [ -n "$mount_unit" ]; then
        if [ -n "$mount_unit" ]; then
            print_message "Found systemd mount unit: $mount_unit" "$YELLOW"
            
            # Try to stop the mount unit using systemctl
            print_message "Stopping systemd mount unit..." "$YELLOW"
            sudo systemctl stop "$mount_unit" 2>/dev/null
            
            # Check if it's still active
            if systemctl is-active --quiet "$mount_unit"; then
                print_message "⚠️ Failed to stop mount unit, trying manual unmount..." "$YELLOW"
            else
                print_message "✅ Successfully stopped systemd mount unit" "$GREEN"
                return 0
            fi
        else
            print_message "Found tmpfs mount at $hls_mount, attempting to unmount..." "$YELLOW"
        fi
        
        # Try regular unmount approaches as fallback
        # Try regular unmount first
        umount "$hls_mount" 2>/dev/null
        
        # If still mounted, try with force flag
        if mount | grep -q "$hls_mount"; then
            umount -f "$hls_mount" 2>/dev/null
        fi
        
        # If still mounted, try with sudo
        if mount | grep -q "$hls_mount"; then
            sudo umount "$hls_mount" 2>/dev/null
        fi
        
        # If still mounted, try sudo with force flag
        if mount | grep -q "$hls_mount"; then
            sudo umount -f "$hls_mount" 2>/dev/null
        fi
        
        # If still mounted, try with lazy unmount as last resort
        if mount | grep -q "$hls_mount"; then
            print_message "⚠️ Regular unmount failed, trying lazy unmount..." "$YELLOW"
            sudo umount -l "$hls_mount" 2>/dev/null
        fi
        
        # Final check
        if mount | grep -q "$hls_mount"; then
            print_message "❌ Failed to unmount $hls_mount" "$RED"
            print_message "You may need to reboot the system to fully remove it" "$YELLOW"
        else
            print_message "✅ Successfully unmounted $hls_mount" "$GREEN"
        fi
    else
        print_message "No tmpfs mount found at $hls_mount" "$GREEN"
    fi
}

# Function to download base config file
download_base_config() {
    # If config file already exists and we're not doing a fresh install, just use the existing config
    if [ -f "$CONFIG_FILE" ] && [ "$FRESH_INSTALL" != "true" ]; then
        print_message "✅ Using existing configuration file: " "$GREEN" "nonewline"
        print_message "$CONFIG_FILE" "$NC"
        return 0
    fi
    
    print_message "\n📥 Downloading base configuration file from GitHub to: " "$YELLOW" "nonewline"
    print_message "$CONFIG_FILE" "$NC"
    
    # Download new config to temporary file first
    local temp_config="/tmp/config.yaml.new"
    if ! curl -s --fail https://raw.githubusercontent.com/tphakala/birdnet-go/main/internal/conf/config.yaml > "$temp_config"; then
        send_telemetry_event "error" "Configuration download failed" "error" "step=download_base_config"
        print_message "❌ Failed to download configuration template" "$RED"
        print_message "This could be due to:" "$YELLOW"
        print_message "- No internet connection or DNS resolution failed" "$YELLOW"
        print_message "- Firewall blocking outgoing connections" "$YELLOW"
        print_message "- GitHub being unreachable" "$YELLOW"
        print_message "\nPlease check your internet connection and try again." "$YELLOW"
        rm -f "$temp_config"
        exit 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if cmp -s "$CONFIG_FILE" "$temp_config"; then
            print_message "✅ Base configuration already exists" "$GREEN"
            rm -f "$temp_config"
        else
            print_message "⚠️ Existing configuration file found." "$YELLOW"
            print_message "❓ Do you want to overwrite it? Backup of current configuration will be created (y/n): " "$YELLOW" "nonewline"
            read -r response
            
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # Create backup with timestamp
                local backup_file
                backup_file="${CONFIG_FILE}.$(date '+%Y%m%d_%H%M%S').backup"
                cp "$CONFIG_FILE" "$backup_file"
                print_message "✅ Backup created: " "$GREEN" "nonewline"
                print_message "$backup_file" "$NC"
                
                mv "$temp_config" "$CONFIG_FILE"
                print_message "✅ Configuration updated successfully" "$GREEN"
            else
                print_message "✅ Keeping existing configuration file" "$YELLOW"
                rm -f "$temp_config"
            fi
        fi
    else
        mv "$temp_config" "$CONFIG_FILE"
        print_message "✅ Base configuration downloaded successfully" "$GREEN"
    fi
    
    # Always ensure clips path is absolute, regardless of whether config was updated or existing
    print_message "\n🔧 Checking audio export path configuration..." "$YELLOW"
    if convert_relative_to_absolute_path "$CONFIG_FILE" "/data/clips/"; then
        print_message "✅ Audio export path updated to absolute path" "$GREEN"
    else
        print_message "ℹ️ Audio export path already absolute; no changes made" "$YELLOW"
    fi
}

# Function to test RTSP URL
test_rtsp_url() {
    local url=$1
    
    # Parse URL to get host and port
    if [[ $url =~ rtsp://([^@]+@)?([^:/]+)(:([0-9]+))? ]]; then
        local host="${BASH_REMATCH[2]}"
        local port="${BASH_REMATCH[4]:-554}"  # Default RTSP port is 554
        
        print_message "🧪 Testing connection to $host:$port..." "$YELLOW"
        
        # Test port using timeout and nc, redirect all output to /dev/null
        if ! timeout 5 nc -zv "$host" "$port" &>/dev/null; then
            print_message "❌ Could not connect to $host:$port" "$RED"
            print_message "❓ Do you want to use this URL anyway? (y/n): " "$YELLOW" "nonewline"
            read -r force_continue
            
            if [[ $force_continue == "y" ]]; then
                print_message "⚠️ Continuing with untested RTSP URL" "$YELLOW"
                return 0
            fi
            return 1
        fi
        
        # Skip RTSP stream test, assume connection is good if port is open
        print_message "✅ Port is accessible, continuing with RTSP URL" "$GREEN"
        return 0
    else
        print_message "❌ Invalid RTSP URL format" "$RED"
    fi
    return 1
}

# Function to configure audio input
configure_audio_input() {
    while true; do
        print_message "\n🎤 Audio Capture Configuration" "$GREEN"
        print_message "1) Use sound card" 
        print_message "2) Use RTSP stream"
        print_message "3) Configure later in BirdNET-Go web interface"
        print_message "❓ Select audio input method (1/2/3): " "$YELLOW" "nonewline"
        read -r audio_choice

        case $audio_choice in
            1)
                if configure_sound_card; then
                    break
                fi
                ;;
            2)
                if configure_rtsp_stream; then
                    break
                fi
                ;;
            3)
                print_message "⚠️ Skipping audio input configuration" "$YELLOW"
                print_message "⚠️ You can configure audio input later in BirdNET-Go web interface at Audio Capture Settings" "$YELLOW"
                # MODIFIED: Always include device mapping even when skipping configuration
                AUDIO_ENV="--device /dev/snd"
                break
                ;;
            *)
                print_message "❌ Invalid selection. Please try again." "$RED"
                ;;
        esac
    done
}

# Function to validate audio device
validate_audio_device() {
    local device="$1"
    
    # Check if user is in audio group
    if ! groups "$USER" | grep &>/dev/null "\baudio\b"; then
        print_message "⚠️ User $USER is not in the audio group" "$YELLOW"
        if sudo usermod -aG audio "$USER"; then
            print_message "✅ Added user $USER to audio group" "$GREEN"
            print_message "⚠️ Please log out and log back in for group changes to take effect" "$YELLOW"
            exit 0
        else
            print_message "❌ Failed to add user to audio group" "$RED"
            return 1
        fi
    fi

    # Test audio device access - using LC_ALL=C to force English output
    if ! LC_ALL=C arecord -c 1 -f S16_LE -r 48000 -d 1 -D "$device" /dev/null 2>/dev/null; then
        send_telemetry_event "error" "Audio device validation failed" "error" "step=validate_audio_device,device=$device"
        print_message "❌ Failed to access audio device" "$RED"
        print_message "This could be due to:" "$YELLOW"
        print_message "  • Device is busy" "$YELLOW"
        print_message "  • Insufficient permissions" "$YELLOW"
        print_message "  • Device is not properly connected" "$YELLOW"
        return 1
    else
        print_message "✅ Audio device validated successfully, tested 48kHz 16-bit mono capture" "$GREEN"
    fi
    
    return 0
}

# Function to configure sound card
configure_sound_card() {
    while true; do
        print_message "\n🎤 Detected audio devices:" "$GREEN"
        
        # Create arrays to store device information
        declare -a devices
        local default_selection=0
        
        # Capture arecord output to a variable first, forcing English locale 
        local arecord_output
        arecord_output=$(LC_ALL=C arecord -l 2>/dev/null)
        
        if [ -z "$arecord_output" ]; then
            print_message "❌ No audio capture devices found!" "$RED"
            return 1
        fi
        
        # Parse arecord output and create a numbered list
        while IFS= read -r line; do
            if [[ $line =~ ^card[[:space:]]+([0-9]+)[[:space:]]*:[[:space:]]*([^,]+),[[:space:]]*device[[:space:]]+([0-9]+)[[:space:]]*:[[:space:]]*([^[]+)[[:space:]]*\[(.*)\] ]]; then
                card_num="${BASH_REMATCH[1]}"
                card_name="${BASH_REMATCH[2]}"
                device_num="${BASH_REMATCH[3]}"
                device_name="${BASH_REMATCH[4]}"
                device_desc="${BASH_REMATCH[5]}"
                # Clean up names
                card_name=$(echo "$card_name" | sed 's/\[//g' | sed 's/\]//g' | xargs)
                device_name=$(echo "$device_name" | xargs)
                device_desc=$(echo "$device_desc" | xargs)
                
                devices+=("$device_desc")
                
                # Set first USB device as default
                if [[ "$card_name" =~ USB && $default_selection -eq 0 ]]; then
                    default_selection=${#devices[@]}
                fi
                
                echo "[$((${#devices[@]}))] Card $card_num: $card_name"
                echo "    Device $device_num: $device_name [$device_desc]"
            fi
        done <<< "$arecord_output"

        if [ ${#devices[@]} -eq 0 ]; then
            print_message "❌ No audio capture devices found!" "$RED"
            return 1
        fi

        # If no USB device was found, use first device as default
        if [ "$default_selection" -eq 0 ]; then
            default_selection=1
        fi

        print_message "\nPlease select a device number from the list above (1-${#devices[@]}) [${default_selection}] or 'b' to go back: " "$YELLOW" "nonewline"
        read -r selection

        if [ "$selection" = "b" ]; then
            return 1
        fi

        # If empty, use default selection
        if [ -z "$selection" ]; then
            selection=$default_selection
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#devices[@]}" ]; then
            local friendly_name="${devices[$((selection-1))]}"
            
            # Parse the original arecord output to get the correct card and device numbers
            local card_num
            local device_num
            local index=1
            while IFS= read -r line; do
                if [[ "$line" =~ ^card[[:space:]]+([0-9]+)[[:space:]]*:[[:space:]]*([^,]+),[[:space:]]*device[[:space:]]+([0-9]+) ]]; then
                    if [ "$index" -eq "$selection" ]; then
                        card_num="${BASH_REMATCH[1]}"
                        device_num="${BASH_REMATCH[3]}"
                        break
                    fi
                    ((index++))
                fi
            done <<< "$(LC_ALL=C arecord -l)"
            
            ALSA_CARD="$friendly_name"
            print_message "✅ Selected capture device: " "$GREEN" "nonewline"
            print_message "$ALSA_CARD"

            # Update config file with the friendly name
            sed -i "s/source: \"sysdefault\"/source: \"${ALSA_CARD}\"/" "$CONFIG_FILE"
            # Comment out RTSP section
            sed -i '/rtsp:/,/      # - rtsp/s/^/#/' "$CONFIG_FILE"
                
            AUDIO_ENV="--device /dev/snd"
            return 0
        else
            print_message "❌ Invalid selection. Please try again." "$RED"
        fi
    done
}

# Function to configure RTSP stream
configure_rtsp_stream() {
    while true; do
        print_message "\n🎥 RTSP Stream Configuration" "$GREEN"
        print_message "Configure primary RTSP stream. Additional streams can be added later via web interface at Audio Capture Settings." "$YELLOW"
        print_message "Enter RTSP URL (format: rtsp://user:password@address:port/path) or 'b' to go back: " "$YELLOW" "nonewline"
        read -r RTSP_URL

        if [ "$RTSP_URL" = "b" ]; then
            return 1
        fi
        
        if [[ ! $RTSP_URL =~ ^rtsp:// ]]; then
            print_message "❌ Invalid RTSP URL format. Please try again." "$RED"
            continue
        fi
        
        if test_rtsp_url "$RTSP_URL"; then
            print_message "✅ RTSP connection successful!" "$GREEN"
            
            # Update config file
            sed -i "s|# - rtsp://user:password@example.com/stream1|      - ${RTSP_URL}|" "$CONFIG_FILE"
            # Comment out audio source section
            sed -i '/source: "sysdefault"/s/^/#/' "$CONFIG_FILE"
            
            # MODIFIED: Always include device mapping even with RTSP
            AUDIO_ENV="--device /dev/snd"
            return 0
        else
            print_message "❌ Could not connect to RTSP stream. Do you want to:" "$RED"
            print_message "1) Try again"
            print_message "2) Go back to audio input selection"
            print_message "❓ Select option (1/2): " "$YELLOW" "nonewline"
            read -r retry
            if [ "$retry" = "2" ]; then
                return 1
            fi
        fi
    done
}

# Function to configure audio export format
configure_audio_format() {
    print_message "\n🔊 Audio Export Configuration" "$GREEN"
    print_message "Select audio format for captured sounds:"
    print_message "1) WAV (Uncompressed, largest files)" 
    print_message "2) FLAC (Lossless compression)"
    print_message "3) AAC (High quality, smaller files) - default" 
    print_message "4) MP3 (For legacy use only)" 
    print_message "5) Opus (Best compression)" 
    
    while true; do
        print_message "❓ Select format (1-5) [3]: " "$YELLOW" "nonewline"
        read -r format_choice

        # If empty, use default (AAC)
        if [ -z "$format_choice" ]; then
            format_choice="3"
        fi

        case $format_choice in
            1) format="wav"; break;;
            2) format="flac"; break;;
            3) format="aac"; break;;
            4) format="mp3"; break;;
            5) format="opus"; break;;
            *) print_message "❌ Invalid selection. Please try again." "$RED";;
        esac
    done

    print_message "✅ Selected audio format: " "$GREEN" "nonewline"
    print_message "$format"

    # Update config file
    sed -i "s/type: wav/type: $format/" "$CONFIG_FILE"
}

# Function to configure locale
configure_locale() {
    print_message "\n🌐 Locale Configuration for bird species names" "$GREEN"
    print_message "Available languages:" "$YELLOW"
    
    # Create arrays for locales
    declare -a locale_codes=("en-uk" "en-us" "af" "ar" "bg" "ca" "cs" "zh" "hr" "da" "nl" "et" "fi" "fr" "de" "el" "he" "hi-in" "hu" "is" "id" "it" "ja" "ko" "lv" "lt" "ml" "no" "pl" "pt" "pt-br" "pt-pt" "ro" "ru" "sr" "sk" "sl" "es" "sv" "th" "tr" "uk" "vi-vn")
    declare -a locale_names=("English (UK)" "English (US)" "Afrikaans" "Arabic" "Bulgarian" "Catalan" "Czech" "Chinese" "Croatian" "Danish" "Dutch" "Estonian" "Finnish" "French" "German" "Greek" "Hebrew" "Hindi" "Hungarian" "Icelandic" "Indonesian" "Italian" "Japanese" "Korean" "Latvian" "Lithuanian" "Malayalam" "Norwegian" "Polish" "Portuguese" "Brazilian Portuguese" "Portuguese (Portugal)" "Romanian" "Russian" "Serbian" "Slovak" "Slovenian" "Spanish" "Swedish" "Thai" "Turkish" "Ukrainian" "Vietnamese")
    
    # Display available locales
    for i in "${!locale_codes[@]}"; do
        printf "%2d) %-30s" "$((i+1))" "${locale_names[i]}"
        if [ $((i % 2)) -eq 1 ]; then
            echo
        fi
    done
    echo
    # Add a final newline if the last row is incomplete
    if [ $((${#locale_codes[@]} % 2)) -eq 1 ]; then
        echo
    fi

    while true; do
        print_message "❓ Select your language (1-${#locale_codes[@]}): " "$YELLOW" "nonewline"
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#locale_codes[@]}" ]; then
            LOCALE_CODE="${locale_codes[$((selection-1))]}"
            print_message "✅ Selected language: " "$GREEN" "nonewline"
            print_message "${locale_names[$((selection-1))]}"
            # Update config file - fixed to replace the entire locale value
            sed -i "s/locale: [a-zA-Z0-9_-]*/locale: ${LOCALE_CODE}/" "$CONFIG_FILE"
            break
        else
            print_message "❌ Invalid selection. Please try again." "$RED"
        fi
    done
}

# Function to get location from NordVPN and OpenStreetMap
get_ip_location() {
    # First try NordVPN's service for city/country
    local nordvpn_info
    if nordvpn_info=$(curl -s "https://nordvpn.com/wp-admin/admin-ajax.php" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "action=get_user_info_data" 2>/dev/null) && [ -n "$nordvpn_info" ]; then
        # Check if the response is valid JSON and contains the required fields
        if echo "$nordvpn_info" | jq -e '.city and .country' >/dev/null 2>&1; then
            local city
            local country
            city=$(echo "$nordvpn_info" | jq -r '.city')
            country=$(echo "$nordvpn_info" | jq -r '.country')
            
            if [ "$city" != "null" ] && [ "$country" != "null" ] && [ -n "$city" ] && [ -n "$country" ]; then
                # Use OpenStreetMap to get precise coordinates
                local coordinates
                coordinates=$(curl -s "https://nominatim.openstreetmap.org/search?city=${city}&country=${country}&format=json" | jq -r '.[0] | "\(.lat) \(.lon)"')
                
                if [ -n "$coordinates" ] && [ "$coordinates" != "null null" ]; then
                    local lat
                    local lon
                    lat=$(echo "$coordinates" | cut -d' ' -f1)
                    lon=$(echo "$coordinates" | cut -d' ' -f2)
                    echo "$lat|$lon|$city|$country"
                    return 0
                fi
            fi
        fi
    fi

    # If NordVPN fails, try ipapi.co as a fallback
    local ipapi_info
    if ipapi_info=$(curl -s "https://ipapi.co/json/" 2>/dev/null) && [ -n "$ipapi_info" ]; then
        # Check if the response is valid JSON and contains the required fields
        if echo "$ipapi_info" | jq -e '.city and .country_name and .latitude and .longitude' >/dev/null 2>&1; then
            local city
            local country
            local lat
            local lon
            city=$(echo "$ipapi_info" | jq -r '.city')
            country=$(echo "$ipapi_info" | jq -r '.country_name')
            lat=$(echo "$ipapi_info" | jq -r '.latitude')
            lon=$(echo "$ipapi_info" | jq -r '.longitude')
            
            if [ "$city" != "null" ] && [ "$country" != "null" ] && \
               [ "$lat" != "null" ] && [ "$lon" != "null" ] && \
               [ -n "$city" ] && [ -n "$country" ] && \
               [ -n "$lat" ] && [ -n "$lon" ]; then
                echo "$lat|$lon|$city|$country"
                return 0
            fi
        fi
    fi

    return 1
}

# Function to configure timezone
configure_timezone() {
    print_message "\n🕐 Timezone Configuration" "$GREEN"
    print_message "BirdNET-Go needs to know your timezone for accurate timestamps and scheduling" "$YELLOW"
    
    # Get current system timezone
    local system_tz=""
    local detected_tz=""
    
    # Try multiple methods to detect timezone
    if [ -f /etc/timezone ]; then
        system_tz=$(cat /etc/timezone 2>/dev/null | tr -d '\n' | tr -d ' ')
    fi
    
    # Fallback to timedatectl if available
    if [ -z "$system_tz" ] && command_exists timedatectl; then
        system_tz=$(timedatectl show --property=Timezone --value 2>/dev/null | tr -d '\n' | tr -d ' ')
    fi
    
    # Fallback to readlink on /etc/localtime
    if [ -z "$system_tz" ] && [ -L /etc/localtime ]; then
        local tz_path=$(readlink -f /etc/localtime)
        system_tz=${tz_path#/usr/share/zoneinfo/}
    fi
    
    # Default to UTC if we couldn't detect
    if [ -z "$system_tz" ]; then
        system_tz="UTC"
        print_message "⚠️ Could not detect system timezone, defaulting to UTC" "$YELLOW"
    else
        print_message "📍 System timezone detected: $system_tz" "$GREEN"
    fi
    
    # Validate the detected timezone exists
    if [ -f "/usr/share/zoneinfo/$system_tz" ]; then
        detected_tz="$system_tz"
        print_message "✅ Timezone '$system_tz' is valid" "$GREEN"
    else
        print_message "⚠️ System timezone '$system_tz' could not be validated" "$YELLOW"
        detected_tz="UTC"
    fi
    
    # Check for common timezone misconfigurations
    local system_time=$(date +"%Y-%m-%d %H:%M:%S %Z")
    print_message "🕐 Current system time: $system_time" "$YELLOW"
    
    # Ask user to confirm timezone
    print_message "\n❓ Do you want to use the detected timezone '$detected_tz'? (y/n): " "$YELLOW" "nonewline"
    read -r use_detected
    
    if [[ $use_detected != "y" ]]; then
        print_message "\n📋 Common timezone examples:" "$YELLOW"
        print_message "  • US/Eastern, US/Central, US/Mountain, US/Pacific" "$YELLOW"
        print_message "  • Europe/London, Europe/Berlin, Europe/Paris" "$YELLOW"
        print_message "  • Asia/Tokyo, Asia/Singapore, Asia/Dubai" "$YELLOW"
        print_message "  • Australia/Sydney, Australia/Melbourne" "$YELLOW"
        print_message "  • UTC (Coordinated Universal Time)" "$YELLOW"
        
        while true; do
            print_message "\n❓ Enter your timezone (e.g., US/Eastern, Europe/London): " "$YELLOW" "nonewline"
            read -r user_tz
            
            # Validate the timezone
            if [ -f "/usr/share/zoneinfo/$user_tz" ]; then
                detected_tz="$user_tz"
                print_message "✅ Timezone '$user_tz' is valid" "$GREEN"
                
                # Show what time it would be in that timezone
                local tz_time=$(TZ="$user_tz" date +"%Y-%m-%d %H:%M:%S %Z")
                print_message "🕐 Time in $user_tz: $tz_time" "$YELLOW"
                
                print_message "❓ Is this the correct time for your location? (y/n): " "$YELLOW" "nonewline"
                read -r confirm_time
                
                if [[ $confirm_time == "y" ]]; then
                    break
                else
                    print_message "Let's try again with a different timezone" "$YELLOW"
                fi
            else
                print_message "❌ Invalid timezone '$user_tz'" "$RED"
                print_message "💡 Tip: You can list all available timezones with: timedatectl list-timezones" "$YELLOW"
                print_message "   Or check /usr/share/zoneinfo/ directory" "$YELLOW"
            fi
        done
    fi
    
    # Store the validated timezone for use in systemd service
    CONFIGURED_TZ="$detected_tz"
    
    # Provide guidance on system timezone if it differs
    if [ "$system_tz" != "$detected_tz" ] && [ "$system_tz" != "UTC" ]; then
        print_message "\n⚠️ NOTE: Your system timezone ($system_tz) differs from the configured timezone ($detected_tz)" "$YELLOW"
        print_message "BirdNET-Go will use: $detected_tz" "$YELLOW"
        print_message "\nTo change your system timezone to match, you can run:" "$YELLOW"
        print_message "  sudo timedatectl set-timezone $detected_tz" "$NC"
        print_message "This ensures all system services use the same timezone" "$YELLOW"
    fi
    
    print_message "\n✅ Timezone configuration complete: $detected_tz" "$GREEN"
}

# Function to configure location
configure_location() {
    print_message "\n🌍 Location Configuration, this is used to limit bird species present in your region" "$GREEN"
    
    # Try to get location from NordVPN/OpenStreetMap
    local ip_location
    if ip_location=$(get_ip_location); then
        local ip_lat
        local ip_lon
        local ip_city
        local ip_country
        ip_lat=$(echo "$ip_location" | cut -d'|' -f1)
        ip_lon=$(echo "$ip_location" | cut -d'|' -f2)
        ip_city=$(echo "$ip_location" | cut -d'|' -f3)
        ip_country=$(echo "$ip_location" | cut -d'|' -f4)
        
        print_message "📍 Based on your IP address, your location appears to be: " "$YELLOW" "nonewline"
        print_message "$ip_city, $ip_country ($ip_lat, $ip_lon)" "$NC"
        print_message "❓ Would you like to use this location? (y/n): " "$YELLOW" "nonewline"
        read -r use_ip_location
        
        if [[ $use_ip_location == "y" ]]; then
            lat=$ip_lat
            lon=$ip_lon
            print_message "✅ Using IP-based location" "$GREEN"
            # Update config file and return
            sed -i "s/latitude: 00.000/latitude: $lat/" "$CONFIG_FILE"
            sed -i "s/longitude: 00.000/longitude: $lon/" "$CONFIG_FILE"
            return
        fi
    else
        print_message "⚠️ Could not automatically determine location" "$YELLOW"
    fi
    
    # If automatic location failed or was rejected, continue with manual input
    print_message "1) Enter coordinates manually" "$YELLOW"
    print_message "2) Enter city name for OpenStreetMap lookup" "$YELLOW"
    
    while true; do
        print_message "❓ Select location input method (1/2): " "$YELLOW" "nonewline"
        read -r location_choice

        case $location_choice in
            1)
                while true; do
                    read -r -p "Enter latitude (-90 to 90): " lat
                    read -r -p "Enter longitude (-180 to 180): " lon
                    
                    if [[ "$lat" =~ ^-?[0-9]*\.?[0-9]+$ ]] && \
                       [[ "$lon" =~ ^-?[0-9]*\.?[0-9]+$ ]] && \
                       (( $(echo "$lat >= -90 && $lat <= 90" | bc -l) )) && \
                       (( $(echo "$lon >= -180 && $lon <= 180" | bc -l) )); then
                        break
                    else
                        print_message "❌ Invalid coordinates. Please try again." "$RED"
                    fi
                done
                break
                ;;
            2)
                while true; do
                    print_message "Enter location (e.g., 'Helsinki, Finland', 'New York, US', or 'Sungei Buloh, Singapore'): " "$YELLOW" "nonewline"
                    read -r location
                    
                    # Split input into city and country
                    city=$(echo "$location" | cut -d',' -f1 | xargs)
                    country=$(echo "$location" | cut -d',' -f2 | xargs)
                    
                    if [ -z "$city" ] || [ -z "$country" ]; then
                        print_message "❌ Invalid format. Please use format: 'City, Country'" "$RED"
                        continue
                    fi
                    
                    # Use OpenStreetMap Nominatim API to get coordinates
                    coordinates=$(curl -s "https://nominatim.openstreetmap.org/search?city=${city}&country=${country}&format=json" | jq -r '.[0] | "\(.lat) \(.lon)"')
                    
                    if [ -n "$coordinates" ] && [ "$coordinates" != "null null" ]; then
                        lat=$(echo "$coordinates" | cut -d' ' -f1)
                        lon=$(echo "$coordinates" | cut -d' ' -f2)
                        print_message "✅ Found coordinates for $city, $country: " "$GREEN" "nonewline"
                        print_message "$lat, $lon"
                        break
                    else
                        print_message "❌ Could not find coordinates. Please try again with format: 'City, Country'" "$RED"
                    fi
                done
                break
                ;;
            *)
                print_message "❌ Invalid selection. Please try again." "$RED"
                ;;
        esac
    done

    # Update config file
    sed -i "s/latitude: 00.000/latitude: $lat/" "$CONFIG_FILE"
    sed -i "s/longitude: 00.000/longitude: $lon/" "$CONFIG_FILE"
}

# Function to configure basic authentication
configure_auth() {
    print_message "\n🔒 Security Configuration" "$GREEN"
    print_message "Do you want to enable password protection for the settings interface?" "$YELLOW"
    print_message "This is highly recommended if BirdNET-Go will be accessible from the internet." "$YELLOW"
    print_message "❓ Enable password protection? (y/n): " "$YELLOW" "nonewline"
    read -r enable_auth

    if [[ $enable_auth == "y" ]]; then
        while true; do
            read -r -p "Enter password: " password
            read -r -p "Confirm password: " password2
            
            if [ "$password" = "$password2" ]; then
                # Generate password hash (using bcrypt)
                password_hash=$(echo -n "$password" | htpasswd -niB "" | cut -d: -f2)
                
                # Update config file - using different delimiter for sed
                sed -i "s|enabled: false    # true to enable basic auth|enabled: true    # true to enable basic auth|" "$CONFIG_FILE"
                sed -i "s|password: \"\"|password: \"$password_hash\"|" "$CONFIG_FILE"
                
                print_message "✅ Password protection enabled successfully!" "$GREEN"
                print_message "If you forget your password, you can reset it by editing:" "$YELLOW"
                print_message "$CONFIG_FILE" "$YELLOW"
                sleep 3
                break
            else
                print_message "❌ Passwords don't match. Please try again." "$RED"
            fi
        done
    fi
}

# Function to check if a port is in use
check_port_availability() {
    local port="$1"
    
    # Try multiple methods to ensure portability
    # First try netcat if available
    if command_exists nc; then
        if nc -z localhost "$port" 2>/dev/null; then
            return 1 # Port is in use
        else
            return 0 # Port is available
        fi
    # Then try ss from iproute2, which is common on modern Linux
    elif command_exists ss; then
        if ss -lnt | grep -q ":$port "; then
            return 1 # Port is in use
        else
            return 0 # Port is available
        fi
    # Then try lsof
    elif command_exists lsof; then
        if lsof -i:"$port" >/dev/null 2>&1; then
            return 1 # Port is in use
        else
            return 0 # Port is available
        fi
    # Finally try a direct connection with timeout
    else
        # Try to connect to the port, timeout after 1 second
        if (echo > /dev/tcp/localhost/"$port") >/dev/null 2>&1; then
            return 1 # Port is in use
        else
            return 0 # Port is available
        fi
    fi
}

# Function to configure web interface port
configure_web_port() {
    # Default port
    WEB_PORT=8080
    
    print_message "\n🔌 Checking web interface port availability..." "$YELLOW"
    
    if ! check_port_availability $WEB_PORT; then
        print_message "❌ Port $WEB_PORT is already in use" "$RED"
        
        while true; do
            print_message "Please enter a different port number (1024-65535): " "$YELLOW" "nonewline"
            read -r custom_port
            
            # Validate port number
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 1024 ] && [ "$custom_port" -le 65535 ]; then
                if check_port_availability "$custom_port"; then
                    WEB_PORT="$custom_port"
                    print_message "✅ Port $WEB_PORT is available" "$GREEN"
                    break
                else
                    print_message "❌ Port $custom_port is also in use. Please try another port." "$RED"
                fi
            else
                print_message "❌ Invalid port number. Please enter a number between 1024 and 65535." "$RED"
            fi
        done
    else
        print_message "✅ Default port $WEB_PORT is available" "$GREEN"
    fi
    
    # Update config file with port
    sed -i "s/port: 8080/port: $WEB_PORT/" "$CONFIG_FILE"
}

# Generate systemd service content
generate_systemd_service_content() {
    # Use configured timezone if available, otherwise fall back to system timezone
    local TZ
    if [ -n "$CONFIGURED_TZ" ]; then
        TZ="$CONFIGURED_TZ"
    elif [ -f /etc/timezone ]; then
        TZ=$(cat /etc/timezone)
    else
        TZ="UTC"
    fi

    # Determine host UID/GID even when executed with sudo
    local HOST_UID=${SUDO_UID:-$(id -u)}
    local HOST_GID=${SUDO_GID:-$(id -g)}

    # Check for /dev/snd/
    local audio_env_line=""
    if check_directory_exists "/dev/snd/"; then
        audio_env_line="--device /dev/snd \\"
    fi

    # Check for /sys/class/thermal, used for Raspberry Pi temperature reporting in system dashboard
    local thermal_volume_line=""
    if check_directory_exists "/sys/class/thermal"; then
        thermal_volume_line="-v /sys/class/thermal:/sys/class/thermal \\"
    fi

    # Check if running on Raspberry Pi and add WiFi power save disable script
    local wifi_power_save_script=""
    if is_raspberry_pi; then
        # Create the script that will be executed
        wifi_power_save_script="# Disable WiFi power saving on Raspberry Pi to prevent connection drops
ExecStartPre=/bin/bash -c 'for interface in /sys/class/net/wlan* /sys/class/net/wlp*; do if [ -d \"\$interface\" ]; then iface=\$(basename \"\$interface\"); (command -v iwconfig >/dev/null 2>&1 && iwconfig \"\$iface\" power off 2>/dev/null) || (command -v iw >/dev/null 2>&1 && iw dev \"\$iface\" set power_save off 2>/dev/null) || true; fi; done'"
    fi

    cat << EOF
[Unit]
Description=BirdNET-Go
After=docker.service
Requires=docker.service
RequiresMountsFor=${CONFIG_DIR}/hls

[Service]
Restart=always
# Remove any existing birdnet-go container to prevent name conflicts
ExecStartPre=-/usr/bin/docker rm -f birdnet-go
# Create tmpfs mount for HLS segments
ExecStartPre=/bin/mkdir -p ${CONFIG_DIR}/hls
# Mount tmpfs, the '|| true' ensures it doesn't fail if already mounted
ExecStartPre=/bin/sh -c 'mount -t tmpfs -o size=50M,mode=0755,uid=${HOST_UID},gid=${HOST_GID},noexec,nosuid,nodev tmpfs ${CONFIG_DIR}/hls || true'
${wifi_power_save_script}
ExecStart=/usr/bin/docker run --rm \\
    --name birdnet-go \\
    -p ${WEB_PORT}:8080 \\
    -p 80:80 \\
    -p 443:443 \\
    -p 8090:8090 \\
    --env TZ="${TZ}" \\
    --env BIRDNET_UID=${HOST_UID} \\
    --env BIRDNET_GID=${HOST_GID} \\
    ${audio_env_line}
    -v ${CONFIG_DIR}:/config \\
    -v ${DATA_DIR}:/data \\
    ${thermal_volume_line}
    ${BIRDNET_GO_IMAGE}
# Cleanup tasks on stop
ExecStopPost=/bin/sh -c 'umount -f ${CONFIG_DIR}/hls || true'
ExecStopPost=-/usr/bin/docker rm -f birdnet-go

[Install]
WantedBy=multi-user.target
EOF
}

# Function to add systemd service configuration
add_systemd_config() {
    # Create systemd service
    print_message "\n🚀 Creating systemd service..." "$GREEN"
    sudo tee /etc/systemd/system/birdnet-go.service << EOF
$(generate_systemd_service_content)
EOF

    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable birdnet-go.service
}

# Function to check if systemd service file needs update
check_systemd_service() {
    local service_file="/etc/systemd/system/birdnet-go.service"
    local temp_service_file="/tmp/birdnet-go.service.new"
    local needs_update=false
    
    # Create temporary service file with current configuration
    generate_systemd_service_content > "$temp_service_file"

    # Check if service file exists and compare
    if [ -f "$service_file" ]; then
        if ! cmp -s "$service_file" "$temp_service_file"; then
            needs_update=true
        fi
    else
        needs_update=true
    fi
    
    rm -f "$temp_service_file"
    echo "$needs_update"
}

# Function to check if BirdNET container is running
check_container_running() {
    if command_exists docker && safe_docker ps | grep -q "birdnet-go"; then
        return 0  # Container is running
    else
        return 1  # Container is not running
    fi
}

# Function to get all BirdNET containers (including stopped ones)
get_all_containers() {
    if command_exists docker; then
        safe_docker ps -a --filter name=birdnet-go -q
    else
        echo ""
    fi
}

# Function to stop BirdNET service and container
stop_birdnet_service() {
    local wait_for_stop=${1:-true}
    local max_wait=${2:-30}
    
    print_message "🛑 Stopping BirdNET-Go service..." "$YELLOW"
    sudo systemctl stop birdnet-go.service
    
    # Wait for container to stop if requested
    if [ "$wait_for_stop" = true ] && check_container_running; then
        local waited=0
        while check_container_running && [ "$waited" -lt "$max_wait" ]; do
            sleep 1
            ((waited++))
        done
        
        if check_container_running; then
            print_message "⚠️ Container still running after $max_wait seconds, forcing stop..." "$YELLOW"
            get_all_containers | xargs -r docker stop
        fi
    fi
}

# Function to handle container update process
handle_container_update() {
    local service_needs_update
    service_needs_update=$(check_systemd_service)
    
    print_message "🔄 Checking for updates..." "$YELLOW"
    
    # Extract existing timezone from systemd service file if updating
    if [ -f "/etc/systemd/system/birdnet-go.service" ] && [ -z "$CONFIGURED_TZ" ]; then
        local existing_tz=$(grep -oP '(?<=--env TZ=")[^"]+' /etc/systemd/system/birdnet-go.service 2>/dev/null)
        if [ -n "$existing_tz" ]; then
            CONFIGURED_TZ="$existing_tz"
            print_message "📍 Using existing timezone configuration: $CONFIGURED_TZ" "$GREEN"
        fi
    fi
    
    # Stop the service and container
    stop_birdnet_service
    
    # Clean up existing tmpfs mounts
    cleanup_hls_mount
    
    # Update configuration paths
    update_paths_in_config
    
    # Pull new image
    print_message "📥 Pulling latest nightly image..." "$YELLOW"
    if ! docker pull "${BIRDNET_GO_IMAGE}"; then
        print_message "❌ Failed to pull new image" "$RED"
        return 1
    fi
    
    # MODIFIED: Always ensure AUDIO_ENV is set during updates
    if [ -z "$AUDIO_ENV" ]; then
        AUDIO_ENV="--device /dev/snd"
    fi
    
    # Update systemd service if needed
    if [ "$service_needs_update" = "true" ]; then
        print_message "📝 Updating systemd service..." "$YELLOW"
        add_systemd_config
    fi
    
    # Start the service
    print_message "🚀 Starting BirdNET-Go service..." "$YELLOW"
    sudo systemctl daemon-reload
    if ! sudo systemctl start birdnet-go.service; then
        print_message "❌ Failed to start service" "$RED"
        return 1
    fi
    
    print_message "✅ Update completed successfully" "$GREEN"
    
    # Send upgrade completion telemetry with context
    local system_info
    system_info=$(collect_system_info)
    local os_name=$(echo "$system_info" | jq -r '.os_name' 2>/dev/null || echo "unknown")
    local pi_model=$(echo "$system_info" | jq -r '.pi_model' 2>/dev/null || echo "none")
    local cpu_arch=$(echo "$system_info" | jq -r '.cpu_arch' 2>/dev/null || echo "unknown")
    
    send_telemetry_event "info" "Upgrade completed successfully" "info" "step=handle_container_update,type=upgrade,os=${os_name},pi_model=${pi_model},arch=${cpu_arch},service_updated=${service_needs_update}"
    
    return 0
}

# Function to clean existing installation but preserve user data
disable_birdnet_service_and_remove_containers() {
    # Stop and disable the service fully, then remove any unit files and drop-ins
    sudo systemctl stop birdnet-go.service 2>/dev/null || true
    sudo systemctl disable --now birdnet-go.service 2>/dev/null || true
    # Remove unit file and any leftover symlinks
    sudo rm -f /etc/systemd/system/birdnet-go.service
    sudo rm -f /etc/systemd/system/multi-user.target.wants/birdnet-go.service
    # Also remove any system-installed unit and its drop-in directory
    sudo rm -f /lib/systemd/system/birdnet-go.service
    sudo rm -rf /etc/systemd/system/birdnet-go.service.d
    # Reload systemd and clear any failed state
    sudo systemctl daemon-reload
    sudo systemctl reset-failed birdnet-go.service 2>/dev/null || true
    print_message "✅ Removed systemd service" "$GREEN"

    # Stop and remove containers
    if docker ps -a | grep -q "birdnet-go"; then
        print_message "🛑 Stopping and removing BirdNET-Go containers..." "$YELLOW"
        get_all_containers | xargs -r docker stop
        get_all_containers | xargs -r docker rm
        print_message "✅ Removed containers" "$GREEN"
    fi

    # Remove images
    # Remove images by repository base name (including untagged)
    image_base="${BIRDNET_GO_IMAGE%:*}"
    images_to_remove=$(docker images "${image_base}" -q)
    if [ -n "${images_to_remove}" ]; then
        print_message "🗑️ Removing BirdNET-Go images..." "$YELLOW"
        echo "${images_to_remove}" | xargs -r docker rmi -f
        print_message "✅ Removed images" "$GREEN"
    fi
}

clean_installation_preserve_data() {
    print_message "🧹 Cleaning BirdNET-Go installation (preserving user data)..." "$YELLOW"
    # First ensure any service is stopped
    stop_birdnet_service false
    # Clean up tmpfs mounts before removing service
    cleanup_hls_mount
    # Remove service and containers
    disable_birdnet_service_and_remove_containers
    print_message "✅ BirdNET-Go uninstalled, user data preserved in $CONFIG_DIR and $DATA_DIR" "$GREEN"
    return 0
}

# Function to clean existing installation
clean_installation() {
    print_message "🧹 Cleaning existing installation..." "$YELLOW"
    
    # First ensure any service is stopped
    stop_birdnet_service false
    # Clean up tmpfs mounts before attempting to remove directories
    cleanup_hls_mount
    # Remove service and containers
    disable_birdnet_service_and_remove_containers
    
    # Unified directory removal with simplified error handling
    if [ -d "$CONFIG_DIR" ] || [ -d "$DATA_DIR" ]; then
        print_message "📁 Removing data directories..." "$YELLOW"
        
        # Create a list of errors
        local error_list=""
        
        # Try to remove directories with regular permissions first
        rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || {
            # If that fails, try with sudo
            print_message "⚠️ Some files require elevated permissions to remove, trying with sudo..." "$YELLOW"
            sudo rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || {
                # If sudo also fails, collect error information
                print_message "❌ Some files could not be removed even with sudo" "$RED"
                
                # Check which directories still exist and list problematic files
                for dir in "$CONFIG_DIR" "$DATA_DIR"; do
                    if [ -d "$dir" ]; then
                        error_list="${error_list}Files in $dir:\n"
                        find "$dir" -type f 2>/dev/null | while read -r file; do
                            error_list="${error_list}  • $file\n"
                        done
                    fi
                done
            }
        }
        
        # Show error list if there were problems
        if [ -n "$error_list" ]; then
            print_message "The following files could not be removed:" "$RED"
            printf '%b' "$error_list" 
            print_message "\n⚠️ Some cleanup operations failed" "$RED"
            print_message "You may need to manually remove remaining files" "$YELLOW"
            return 1
        else
            print_message "✅ Removed data directories" "$GREEN"
        fi
    fi
    
    print_message "✅ Cleanup completed successfully" "$GREEN"
    return 0
}

# Function to start BirdNET-Go
start_birdnet_go() {   
    print_message "\n🚀 Starting BirdNET-Go..." "$GREEN"
    
    # Check if container is already running
    if check_container_running; then
        print_message "✅ BirdNET-Go container is already running" "$GREEN"
        return 0
    fi
    
    # Start the service
    sudo systemctl start birdnet-go.service
    
    # Check if service started
    if ! sudo systemctl is-active --quiet birdnet-go.service; then
        send_telemetry_event "error" "Service startup failed" "error" "step=start_birdnet_go"
        print_message "❌ Failed to start BirdNET-Go service" "$RED"
        
        # Get and display journald logs for troubleshooting
        print_message "\n📋 Service logs (last 20 entries):" "$YELLOW"
        journalctl -u birdnet-go.service -n 20 --no-pager
        
        print_message "\n❗ If you need help with this issue:" "$RED"
        print_message "1. Check port availability and permissions" "$YELLOW"
        print_message "2. Verify your audio device is properly connected and accessible" "$YELLOW"
        print_message "3. If the issue persists, please open a ticket at:" "$YELLOW"
        print_message "   https://github.com/tphakala/birdnet-go/issues" "$GREEN"
        print_message "   Include the logs above in your issue report for faster troubleshooting" "$YELLOW"
        
        exit 1
    fi
    print_message "✅ BirdNET-Go service started successfully!" "$GREEN"
    # Determine if this is a fresh install or an upgrade
    local install_type="installation"
    if [ "$FRESH_INSTALL" = "true" ]; then
        install_type="installation"
    else
        install_type="upgrade"
    fi
    
    # Send appropriate telemetry event with more context
    local system_info
    system_info=$(collect_system_info)
    local os_name=$(echo "$system_info" | jq -r '.os_name' 2>/dev/null || echo "unknown")
    local pi_model=$(echo "$system_info" | jq -r '.pi_model' 2>/dev/null || echo "none")
    local cpu_arch=$(echo "$system_info" | jq -r '.cpu_arch' 2>/dev/null || echo "unknown")
    
    send_telemetry_event "info" "${install_type^} completed successfully" "info" "step=start_birdnet_go,type=${install_type},os=${os_name},pi_model=${pi_model},arch=${cpu_arch},port=${WEB_PORT}"

    print_message "\n🐳 Waiting for container to start..." "$YELLOW"
    
    # Wait for container to appear and be running (max 30 seconds)
    local max_attempts=30
    local attempt=1
    local container_id=""
    
    while [ "$attempt" -le "$max_attempts" ]; do
        container_id=$(docker ps --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}")
        if [ -n "$container_id" ]; then
            print_message "✅ Container started successfully!" "$GREEN"
            break
        fi
        
        # Check if service is still running
        if ! sudo systemctl is-active --quiet birdnet-go.service; then
            print_message "❌ Service stopped unexpectedly" "$RED"
            print_message "Checking service logs:" "$YELLOW"
            journalctl -u birdnet-go.service -n 50 --no-pager
            
            print_message "\n❗ If you need help with this issue:" "$RED"
            print_message "1. The service started but then crashed" "$YELLOW"
            print_message "2. Please open a ticket at:" "$YELLOW"
            print_message "   https://github.com/tphakala/birdnet-go/issues" "$GREEN"
            print_message "   Include the logs above in your issue report for faster troubleshooting" "$YELLOW"
            
            exit 1
        fi
        
        print_message "⏳ Waiting for container to start (attempt $attempt/$max_attempts)..." "$YELLOW"
        sleep 1
        ((attempt++))
    done

    if [ -z "$container_id" ]; then
        print_message "❌ Container failed to start within ${max_attempts} seconds" "$RED"
        print_message "Service logs:" "$YELLOW"
        journalctl -u birdnet-go.service -n 50 --no-pager
        
        print_message "\nDocker logs:" "$YELLOW"
        docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | xargs -r docker logs
        
        print_message "\n❗ If you need help with this issue:" "$RED"
        print_message "1. The service started but container didn't initialize properly" "$YELLOW"
        print_message "2. Please open a ticket at:" "$YELLOW"
        print_message "   https://github.com/tphakala/birdnet-go/issues" "$GREEN"
        print_message "   Include the logs above in your issue report for faster troubleshooting" "$YELLOW"
        
        exit 1
    fi

    # Wait additional time for application to initialize
    print_message "⏳ Waiting for application to initialize..." "$YELLOW"
    sleep 5

    # Show logs from systemd service instead of container
    print_message "\n📝 Service logs:" "$GREEN"
    journalctl -u birdnet-go.service -n 20 --no-pager
    
    print_message "\nTo follow logs in real-time, use:" "$YELLOW"
    print_message "journalctl -fu birdnet-go.service" "$NC"
}

# Function to check if system is a Raspberry Pi
is_raspberry_pi() {
    if [ -f /proc/device-tree/model ]; then
        local model
        model=$(tr -d '\0' < /proc/device-tree/model)
        if [[ "$model" == *"Raspberry Pi"* ]]; then
            return 0  # True - is a Raspberry Pi
        fi
    fi
    return 1  # False - not a Raspberry Pi
}

# Function to disable WiFi power saving for a specific interface
disable_wifi_power_save_interface() {
    local interface="$1"
    
    # Check if iwconfig is available
    if command -v iwconfig >/dev/null 2>&1; then
        # Try to disable power management using iwconfig
        iwconfig "$interface" power off 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Disabled WiFi power saving on $interface (iwconfig)"
            return 0
        fi
    fi
    
    # Check if iw is available (modern tool)
    if command -v iw >/dev/null 2>&1; then
        # Try to disable power management using iw
        iw dev "$interface" set power_save off 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Disabled WiFi power saving on $interface (iw)"
            return 0
        fi
    fi
    
    # Also try to set it via sysfs if available
    local power_save_path="/sys/class/net/$interface/device/power/control"
    if [ -f "$power_save_path" ]; then
        echo "on" > "$power_save_path" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Disabled WiFi power saving on $interface (sysfs)"
            return 0
        fi
    fi
    
    return 1
}

# Function to disable WiFi power saving on all WLAN interfaces
disable_wifi_power_save() {
    local success=false
    
    # Find all wireless interfaces
    for interface in /sys/class/net/wlan*; do
        if [ -d "$interface" ]; then
            interface_name=$(basename "$interface")
            if disable_wifi_power_save_interface "$interface_name"; then
                success=true
            fi
        fi
    done
    
    # Also check for interfaces with different naming (e.g., wlp*)
    for interface in /sys/class/net/wlp*; do
        if [ -d "$interface" ]; then
            interface_name=$(basename "$interface")
            # Check if it's actually a wireless interface
            if [ -d "$interface/wireless" ] || [ -d "$interface/phy80211" ]; then
                if disable_wifi_power_save_interface "$interface_name"; then
                    success=true
                fi
            fi
        fi
    done
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to detect Raspberry Pi model
detect_rpi_model() {
    if [ -f /proc/device-tree/model ]; then
        local model
        model=$(tr -d '\0' < /proc/device-tree/model)
        case "$model" in
            *"Raspberry Pi 5"*)
                print_message "✅ Detected Raspberry Pi 5" "$GREEN"
                return 5
                ;;
            *"Raspberry Pi 4"*)
                print_message "✅ Detected Raspberry Pi 4" "$GREEN"
                return 4
                ;;
            *"Raspberry Pi 3"*)
                print_message "✅ Detected Raspberry Pi 3" "$GREEN"
                return 3
                ;;
            *"Raspberry Pi Zero 2"*)
                print_message "✅ Detected Raspberry Pi Zero 2" "$GREEN"
                return 2
                ;;
            *)
                print_message "ℹ️ Unknown Raspberry Pi model: $model" "$YELLOW"
                return 0
                ;;
        esac
    fi

    # Return 0 if no Raspberry Pi model is detected
    return 0
}

# Function to configure performance settings based on RPi model
optimize_settings() {
    print_message "\n⏱️ Optimizing settings based on system performance" "$GREEN"
    # enable XNNPACK delegate for inference acceleration
    sed -i 's/usexnnpack: false/usexnnpack: true/' "$CONFIG_FILE"
    print_message "✅ Enabled XNNPACK delegate for inference acceleration" "$GREEN"

    # Check if system is Raspberry Pi and inform about WiFi power saving
    if is_raspberry_pi; then
        print_message "🔧 WiFi power saving will be disabled on startup to prevent connection drops" "$YELLOW"
    fi

    # Detect RPi model
    detect_rpi_model
    local rpi_model=$?
    
    case $rpi_model in
        5)
            # RPi 5 settings
            sed -i 's/overlap: 1.5/overlap: 2.7/' "$CONFIG_FILE"
            print_message "✅ Applied optimized settings for Raspberry Pi 5" "$GREEN"
            ;;
        4)
            # RPi 4 settings
            sed -i 's/overlap: 1.5/overlap: 2.6/' "$CONFIG_FILE"
            print_message "✅ Applied optimized settings for Raspberry Pi 4" "$GREEN"
            ;;
        3)
            # RPi 3 settings
            sed -i 's/overlap: 1.5/overlap: 2.0/' "$CONFIG_FILE"
            print_message "✅ Applied optimized settings for Raspberry Pi 3" "$GREEN"
            ;;
        2)
            # RPi Zero 2 settings
            sed -i 's/overlap: 1.5/overlap: 2.0/' "$CONFIG_FILE"
            print_message "✅ Applied optimized settings for Raspberry Pi Zero 2" "$GREEN"
            ;;
    esac
}

# Function to validate installation
validate_installation() {
    print_message "\n🔍 Validating installation..." "$YELLOW"
    local checks=0
    
    # Check Docker container
    if check_container_running; then
        ((checks++))
    fi
    
    # Check service status
    if systemctl is-active --quiet birdnet-go.service; then
        ((checks++))
    fi
    
    # Check web interface
    if curl -s "http://localhost:${WEB_PORT}" >/dev/null; then
        ((checks++))
    fi
    
    if [ "$checks" -eq 3 ]; then
        print_message "✅ Installation validated successfully" "$GREEN"
        return 0
    fi
    print_message "⚠️ Installation validation failed" "$RED"
    return 1
}

# Function to get current container version
get_container_version() {
    local image_name="$1"
    local current_version=""
    
    if ! command_exists docker; then
        echo ""
        return
    fi
    
    # Try to get the version from the running container first
    current_version=$(safe_docker ps --format "{{.Image}}" | grep "birdnet-go" | cut -d: -f2)
    
    # If no running container, check if image exists locally
    if [ -z "$current_version" ]; then
        current_version=$(safe_docker images --format "{{.Tag}}" "$image_name" | head -n1)
    fi
    
    echo "$current_version"
}

# Default paths
CONFIG_DIR="$HOME/birdnet-go-app/config"
DATA_DIR="$HOME/birdnet-go-app/data"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
WEB_PORT=8080  # Default web port
# MODIFIED: Set default AUDIO_ENV to always include device mapping
AUDIO_ENV="--device /dev/snd"
# Flag for fresh installation
FRESH_INSTALL="false"
# Configured timezone (will be set during configuration)
CONFIGURED_TZ=""

# Load telemetry configuration if it exists
load_telemetry_config

# Installation status check
INSTALLATION_TYPE=$(check_birdnet_installation)
PRESERVED_DATA=false

# Add debug output to understand detection results
if [ "$INSTALLATION_TYPE" = "full" ]; then
    print_message "DEBUG: Detected full installation (service + Docker)" "$YELLOW" > /dev/null
elif [ "$INSTALLATION_TYPE" = "docker" ]; then
    print_message "DEBUG: Detected Docker-only installation" "$YELLOW" > /dev/null
else
    print_message "DEBUG: No installation detected" "$YELLOW" > /dev/null
fi

if check_preserved_data; then
    PRESERVED_DATA=true
fi

# Function to display menu options based on installation type
display_menu() {
    local installation_type="$1"
    
    if [ "$installation_type" = "full" ]; then
        print_message "🔍 Found existing BirdNET-Go installation (systemd service)" "$YELLOW"
        print_message "1) Check for updates" "$YELLOW"
        print_message "2) Fresh installation" "$YELLOW"
        print_message "3) Uninstall BirdNET-Go, remove data" "$YELLOW"
        print_message "4) Uninstall BirdNET-Go, preserve data" "$YELLOW"
        print_message "5) Exit" "$YELLOW"
        print_message "❓ Select an option (1-5): " "$YELLOW" "nonewline"
        return 5  # Return number of options
    elif [ "$installation_type" = "docker" ]; then
        print_message "🔍 Found existing BirdNET-Go Docker container/image" "$YELLOW"
        print_message "1) Check for updates" "$YELLOW"
        print_message "2) Install as systemd service" "$YELLOW"
        print_message "3) Fresh installation" "$YELLOW"
        print_message "4) Remove Docker container/image" "$YELLOW"
        print_message "5) Exit" "$YELLOW"
        print_message "❓ Select an option (1-5): " "$YELLOW" "nonewline"
        return 5  # Return number of options
    else
        print_message "🔍 Found BirdNET-Go data from previous installation" "$YELLOW"
        print_message "1) Install using existing data and configuration" "$YELLOW"
        print_message "2) Fresh installation (remove existing data and configuration)" "$YELLOW"
        print_message "3) Remove existing data without installing" "$YELLOW"
        print_message "4) Exit" "$YELLOW"
        print_message "❓ Select an option (1-4): " "$YELLOW" "nonewline"
        return 4  # Return number of options
    fi
}

# Modularized menu action handlers
handle_full_install_menu() {
    local selection="$1"
    case $selection in
        1)
            check_network
            if handle_container_update; then
                exit 0
            else
                print_message "⚠️ Update failed" "$RED"
                print_message "❓ Do you want to proceed with fresh installation? (y/n): " "$YELLOW" "nonewline"
                read -r response
                if [[ ! "$response" =~ ^[Yy]$ ]]; then
                    print_message "❌ Installation cancelled" "$RED"
                    exit 1
                fi
                FRESH_INSTALL="true"
            fi
            ;;
        2)
            print_message "\n⚠️  WARNING: Fresh installation will:" "$RED"
            print_message "  • Remove all BirdNET-Go containers and images" "$RED"
            print_message "  • Delete all configuration and data in $CONFIG_DIR" "$RED"
            print_message "  • Delete all recordings and database in $DATA_DIR" "$RED"
            print_message "  • Remove systemd service configuration" "$RED"
            print_message "\n❓ Type 'yes' to proceed with fresh installation: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                clean_installation
                FRESH_INSTALL="true"
            else
                print_message "❌ Installation cancelled" "$RED"
                exit 1
            fi
            ;;
        3)
            print_message "\n⚠️  WARNING: Uninstalling BirdNET-Go will:" "$RED"
            print_message "  • Remove all BirdNET-Go containers and images" "$RED"
            print_message "  • Delete all configuration and data in $CONFIG_DIR" "$RED"
            print_message "  • Delete all recordings and database in $DATA_DIR" "$RED"
            print_message "  • Remove systemd service configuration" "$RED"
            print_message "\n❓ Type 'yes' to proceed with uninstallation: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if clean_installation; then
                    print_message "✅ BirdNET-Go has been successfully uninstalled" "$GREEN"
                else
                    print_message "⚠️ Some components could not be removed" "$RED"
                    print_message "Please check the messages above for details" "$YELLOW"
                fi
                exit 0
            else
                print_message "❌ Uninstallation cancelled" "$RED"
                exit 1
            fi
            ;;
        4)
            print_message "\nℹ️ NOTE: This option will uninstall BirdNET-Go but preserve your data:" "$YELLOW"
            print_message "  • BirdNET-Go containers and images will be removed" "$YELLOW"
            print_message "  • Systemd service will be disabled and removed" "$YELLOW"
            print_message "  • All your data and configuration in $CONFIG_DIR and $DATA_DIR will be preserved" "$GREEN"
            print_message "\n❓ Type 'yes' to proceed with uninstallation (preserve data): " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if clean_installation_preserve_data; then
                    print_message "✅ BirdNET-Go has been successfully uninstalled (user data preserved)" "$GREEN"
                else
                    print_message "⚠️ Some components could not be removed" "$RED"
                    print_message "Please check the messages above for details" "$YELLOW"
                fi
                exit 0
            else
                print_message "❌ Uninstallation cancelled" "$RED"
                exit 1
            fi
            ;;
        5)
            print_message "❌ Operation cancelled" "$RED"
            exit 1
            ;;
        *)
            print_message "❌ Invalid option" "$RED"
            exit 1
            ;;
    esac
}

handle_docker_install_menu() {
    local selection="$1"
    case $selection in
        1)
            check_network
            print_message "\n🔄 Updating BirdNET-Go Docker image..." "$YELLOW"
            if docker pull "${BIRDNET_GO_IMAGE}"; then
                print_message "✅ Successfully updated to latest image" "$GREEN"
                print_message "⚠️ Note: You will need to restart your container to use the updated image" "$YELLOW"
                exit 0
            else
                print_message "❌ Failed to update Docker image" "$RED"
                exit 1
            fi
            ;;
        2)
            print_message "\n🔧 Installing BirdNET-Go as systemd service..." "$GREEN"
            ;;
        3)
            print_message "\n⚠️  WARNING: Fresh installation will:" "$RED"
            print_message "  • Remove all BirdNET-Go containers and images" "$RED"
            print_message "  • Delete all configuration and data in $CONFIG_DIR" "$RED"
            print_message "  • Delete all recordings and database in $DATA_DIR" "$RED"
            print_message "\n❓ Type 'yes' to proceed with fresh installation: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if docker ps -a | grep -q "birdnet-go"; then
                    print_message "🛑 Stopping and removing BirdNET-Go containers..." "$YELLOW"
                    docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | xargs -r docker stop
                    docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | xargs -r docker rm
                    print_message "✅ Removed containers" "$GREEN"
                fi
                image_base="${BIRDNET_GO_IMAGE%:*}"
                images_to_remove=$(docker images "${image_base}" -q)
                if [ -n "${images_to_remove}" ]; then
                    print_message "🗑️ Removing BirdNET-Go images..." "$YELLOW"
                    echo "${images_to_remove}" | xargs -r docker rmi -f
                    print_message "✅ Removed images" "$GREEN"
                fi
                if [ -d "$CONFIG_DIR" ] || [ -d "$DATA_DIR" ]; then
                    print_message "📁 Removing data directories..." "$YELLOW"
                    rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || sudo rm -rf "$CONFIG_DIR" "$DATA_DIR"
                    print_message "✅ Removed data directories" "$GREEN"
                fi
                FRESH_INSTALL="true"
            else
                print_message "❌ Installation cancelled" "$RED"
                exit 1
            fi
            ;;
        4)
            print_message "\n⚠️  WARNING: This will remove BirdNET-Go Docker components:" "$RED"
            print_message "  • Stop and remove all BirdNET-Go containers" "$RED"
            print_message "  • Remove all BirdNET-Go Docker images" "$RED"
            print_message "  • Configuration and data will remain in $CONFIG_DIR and $DATA_DIR" "$GREEN"
            print_message "\n❓ Type 'yes' to proceed with removal: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if docker ps -a | grep -q "birdnet-go"; then
                    print_message "🛑 Stopping and removing BirdNET-Go containers..." "$YELLOW"
                    docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | xargs -r docker stop
                    docker ps -a --filter "ancestor=${BIRDNET_GO_IMAGE}" --format "{{.ID}}" | xargs -r docker rm
                    print_message "✅ Removed containers" "$GREEN"
                fi
                image_base="${BIRDNET_GO_IMAGE%:*}"
                images_to_remove=$(docker images "${image_base}" -q)
                if [ -n "${images_to_remove}" ]; then
                    print_message "🗑️ Removing BirdNET-Go images..." "$YELLOW"
                    echo "${images_to_remove}" | xargs -r docker rmi -f
                    print_message "✅ Removed images" "$GREEN"
                fi
                print_message "✅ BirdNET-Go Docker components removed successfully" "$GREEN"
                exit 0
            else
                print_message "❌ Operation cancelled" "$RED"
                exit 1
            fi
            ;;
        5)
            print_message "❌ Operation cancelled" "$RED"
            exit 1
            ;;
        *)
            print_message "❌ Invalid option" "$RED"
            exit 1
            ;;
    esac
}

handle_preserved_data_menu() {
    local selection="$1"
    case $selection in
        1)
            print_message "\n📝 Installing BirdNET-Go using existing data..." "$GREEN"
            ;;
        2)
            print_message "\n⚠️  WARNING: Fresh installation will remove existing data:" "$RED"
            print_message "  • Delete all configuration and data in $CONFIG_DIR" "$RED"
            print_message "  • Delete all recordings and database in $DATA_DIR" "$RED"
            print_message "\n❓ Type 'yes' to proceed with fresh installation: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if [ -d "$CONFIG_DIR" ] || [ -d "$DATA_DIR" ]; then
                    print_message "📁 Removing data directories..." "$YELLOW"
                    rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || sudo rm -rf "$CONFIG_DIR" "$DATA_DIR"
                    print_message "✅ Removed existing data directories" "$GREEN"
                fi
                FRESH_INSTALL="true"
            else
                print_message "❌ Installation cancelled" "$RED"
                exit 1
            fi
            ;;
        3)
            print_message "\n⚠️  WARNING: This will permanently delete:" "$RED"
            print_message "  • All configuration and data in $CONFIG_DIR" "$RED"
            print_message "  • All recordings and database in $DATA_DIR" "$RED"
            print_message "\n❓ Type 'yes' to proceed with data removal: " "$YELLOW" "nonewline"
            read -r response
            if [ "$response" = "yes" ]; then
                if [ -d "$CONFIG_DIR" ] || [ -d "$DATA_DIR" ]; then
                    print_message "📁 Removing data directories..." "$YELLOW"
                    if ! rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null; then
                        sudo rm -rf "$CONFIG_DIR" "$DATA_DIR"
                    fi
                    print_message "✅ All data has been successfully removed" "$GREEN"
                fi
                exit 0
            else
                print_message "❌ Operation cancelled" "$RED"
                exit 1
            fi
            ;;
        4)
            print_message "❌ Operation cancelled" "$RED"
            exit 1
            ;;
        *)
            print_message "❌ Invalid option" "$RED"
            exit 1
            ;;
    esac
}

# Simplified dispatcher
handle_menu_selection() {
    local installation_type="$1"
    local selection="$2"
    if [ "$installation_type" = "full" ]; then
        handle_full_install_menu "$selection"
    elif [ "$installation_type" = "docker" ]; then
        handle_docker_install_menu "$selection"
    else
        handle_preserved_data_menu "$selection"
    fi
}

# Determine what's installed and what to show
if [ "$INSTALLATION_TYPE" != "none" ] || [ "$PRESERVED_DATA" = true ]; then
    # Display menu based on installation type
    display_menu "$INSTALLATION_TYPE"
    max_options=$?
    
    # Read user selection
    read -r response
    
    # Validate user selection
    if [[ "$response" =~ ^[0-9]+$ ]] && [ "$response" -ge 1 ] && [ "$response" -le "$max_options" ]; then
        # Handle menu selection
        handle_menu_selection "$INSTALLATION_TYPE" "$response"
    else
        print_message "❌ Invalid option" "$RED"
        exit 1
    fi
fi

print_message "Note: Root privileges will be required for:" "$YELLOW"
print_message "  - Installing system packages (alsa-utils, curl, bc, jq, apache2-utils)" "$YELLOW"
print_message "  - Installing Docker" "$YELLOW"
print_message "  - Creating systemd service" "$YELLOW"
print_message ""

# First check basic network connectivity and ensure curl is available
check_network

# Check prerequisites before proceeding
check_prerequisites

# Check if systemd is the init system
check_systemd

# Now proceed with rest of package installation
print_message "\n🔧 Updating package list..." "$YELLOW"
sudo apt -qq update

# Install required packages
print_message "\n🔧 Checking and installing required packages..." "$YELLOW"

# Check which packages need to be installed
REQUIRED_PACKAGES=("alsa-utils" "curl" "bc" "jq" "apache2-utils" "netcat-openbsd" "iproute2" "lsof" "avahi-daemon" "libnss-mdns")
TO_INSTALL=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        TO_INSTALL+=("$pkg")
    else
        print_message "✅ $pkg found" "$GREEN"
    fi
done

# Install missing packages
if [ ${#TO_INSTALL[@]} -gt 0 ]; then
    print_message "🔧 Installing missing packages: ${TO_INSTALL[*]}" "$YELLOW"
    sudo apt clean
    sudo apt update -q
    if sudo apt install -q -y "${TO_INSTALL[@]}"; then
        print_message "✅ All packages installed successfully" "$GREEN"
    else
        print_message "⚠️ Package installation failed, retrying with new apt update and install..." "$YELLOW"
        # Retry with apt update first
        if sudo apt update && sudo apt install -q -y "${TO_INSTALL[@]}"; then
            print_message "✅ All packages installed successfully after update" "$GREEN"
        else
            print_message "❌ Failed to install some packages even after apt update" "$RED"
            exit 1
        fi
    fi
fi

# Pull Docker image
pull_docker_image

# Check if directories can be created
check_directory "$CONFIG_DIR"
check_directory "$DATA_DIR"

# Create directories
print_message "\n🔧 Creating config and data directories..." "$YELLOW"
print_message "📁 Config directory: " "$GREEN" "nonewline"
print_message "$CONFIG_DIR" "$NC"
print_message "📁 Data directory: " "$GREEN" "nonewline"
print_message "$DATA_DIR" "$NC"
mkdir -p "$CONFIG_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/clips"
print_message "✅ Created data directory and clips subdirectory" "$GREEN"

# Download base config file
download_base_config

# Now lets query user for configuration
print_message "\n🔧 Now lets configure some basic settings" "$YELLOW"

# Configure web port
configure_web_port

# Configure audio input
configure_audio_input

# Configure audio format
configure_audio_format

# Configure timezone
configure_timezone

# Configure locale
configure_locale

# Configure location
configure_location

# Configure security
configure_auth

# Configure telemetry (only if not already configured or fresh install)
if [ "$FRESH_INSTALL" = "true" ] || [ "$TELEMETRY_ENABLED" = "" ]; then
    configure_telemetry
else
    print_message "\n📊 Using existing telemetry configuration: $([ "$TELEMETRY_ENABLED" = "true" ] && echo "enabled" || echo "disabled")" "$GREEN"
    # Save telemetry config to ensure install ID is preserved
    save_telemetry_config
fi

# Optimize settings
optimize_settings

# Add systemd service configuration
add_systemd_config

# Start BirdNET-Go
start_birdnet_go

# Validate installation
validate_installation

print_message ""
print_message "✅ Installation completed!" "$GREEN"
print_message "📁 Configuration directory: " "$GREEN" "nonewline"
print_message "$CONFIG_DIR"
print_message "📁 Data directory: " "$GREEN" "nonewline"
print_message "$DATA_DIR"

# Get IP address
IP_ADDR=$(get_ip_address)
if [ -n "$IP_ADDR" ]; then
    print_message "🌐 BirdNET-Go web interface is available at http://${IP_ADDR}:${WEB_PORT}" "$GREEN"
else
    print_message "⚠️ Could not determine IP address - you may access BirdNET-Go at http://localhost:${WEB_PORT}" "$YELLOW"
    print_message "To find your IP address manually, run: ip addr show or nmcli device show" "$YELLOW"
fi

# Check if mDNS is available
if check_mdns; then
    HOSTNAME=$(hostname)
    print_message "🌐 Also available at http://${HOSTNAME}.local:${WEB_PORT}" "$GREEN"
fi

