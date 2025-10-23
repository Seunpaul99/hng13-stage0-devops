#!/bin/bash

################################################################################
#
# AUTOMATED DOCKER DEPLOYMENT SCRIPT
# Author: DevOps Team
# Description: Secure and robust deployment script with comprehensive error handling
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

# Error handler
handle_error() {
    error "Script failed at line $1"
    error "Check log file for details: $LOG_FILE"
    exit 1
}

trap 'handle_error ${LINENO}' ERR

# Validation functions
validate_url() {
    [[ "$1" =~ ^https://.*\.git$ ]] || {
        error "Invalid Git URL format. Must be HTTPS and end with .git"
        return 1
    }
}

validate_ip() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        error "Invalid IP address format"
        return 1
    }
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || {
        error "Invalid port number. Must be between 1-65535"
        return 1
    }
}

validate_ssh_key() {
    local key_path="${1/#\~/$HOME}"
    [ -f "$key_path" ] || {
        error "SSH key not found: $key_path"
        return 1
    }
}

check_dependencies() {
    local deps=("git" "ssh" "scp")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Required dependency not found: $dep"
            exit 1
        fi
    done
    success "All dependencies verified"
}

# Secure PAT handling
get_pat() {
    read -sp "Enter your GitHub Personal Access Token: " PAT
    echo
    [ -n "$PAT" ] || {
        error "PAT cannot be empty"
        exit 1
    }
}

# Collect user inputs with validation
collect_inputs() {
    echo ""
    echo "=== 🚀 Deployment Configuration ==="
    echo ""
    
    # Git Repository
    while true; do
        read -p "Enter GitHub Repo URL (HTTPS): " REPO_URL
        if validate_url "$REPO_URL"; then break; fi
    done
    
    get_pat
    
    read -p "Enter branch name (default: main): " BRANCH
    BRANCH=${BRANCH:-main}
    
    # Server details
    read -p "Enter remote server username: " USER
    [ -n "$USER" ] || {
        error "Username cannot be empty"
        exit 1
    }
    
    while true; do
        read -p "Enter remote server IP address: " SERVER_IP
        if validate_ip "$SERVER_IP"; then break; fi
    done
    
    while true; do
        read -p "Enter SSH key path (e.g., ~/.ssh/id_rsa): " SSH_KEY
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        if validate_ssh_key "$SSH_KEY"; then break; fi
    done
    
    while true; do
        read -p "Enter application port (internal container port): " APP_PORT
        if validate_port "$APP_PORT"; then break; fi
    done
    
    # Derived values
    PROJECT_NAME=$(basename "$REPO_URL" .git | tr '[:upper:]' '[:lower:]')
    AUTH_REPO_URL="${REPO_URL/https:\/\//https://${PAT}@}"
    CONTAINER_NAME="${PROJECT_NAME}_app"
    
    # Summary
    echo ""
    echo "=== Deployment Summary ==="
    log "Project: $PROJECT_NAME"
    log "Branch: $BRANCH"
    log "Server: $USER@$SERVER_IP"
    log "App Port: $APP_PORT"
    log "Container: $CONTAINER_NAME"
    echo ""
    
    read -p "Proceed with deployment? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || {
        log "Deployment cancelled by user"
        exit 0
    }
}

# Repository management
setup_repository() {
    log "Setting up repository..."
    
    if [ -d "$PROJECT_NAME" ]; then
        cd "$PROJECT_NAME"
        log "Updating existing repository..."
        git checkout "$BRANCH" >> "$LOG_FILE" 2>&1
        git pull origin "$BRANCH" >> "$LOG_FILE" 2>&1
    else
        log "Cloning new repository..."
        git clone -b "$BRANCH" "$AUTH_REPO_URL" "$PROJECT_NAME" >> "$LOG_FILE" 2>&1
        cd "$PROJECT_NAME"
    fi
    
    # Verify repository is accessible
    git status >> "$LOG_FILE" 2>&1 || {
        error "Repository access failed. Check URL and PAT."
        exit 1
    }
    
    success "Repository setup completed"
}

# Remote server functions
remote_exec() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${USER}@${SERVER_IP}" "$1" >> "$LOG_FILE" 2>&1
}

remote_copy() {
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
        "$1" "${USER}@${SERVER_IP}:$2" >> "$LOG_FILE" 2>&1
}

test_ssh_connection() {
    log "Testing SSH connection..."
    if remote_exec "echo 'Connection successful'"; then
        success "SSH connection verified"
    else
        error "SSH connection failed. Check credentials and network."
        exit 1
    fi
}

setup_remote_environment() {
    log "Setting up remote environment..."
    
    # Install Docker
    if ! remote_exec "command -v docker &>/dev/null"; then
        log "Installing Docker..."
        remote_exec "curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh" || {
            error "Docker installation failed"
            exit 1
        }
    else
        log "Docker already installed"
    fi
    
    # Install Docker Compose
    if ! remote_exec "command -v docker-compose &>/dev/null"; then
        log "Installing Docker Compose..."
        remote_exec "sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose" || {
            error "Docker Compose installation failed"
            exit 1
        }
    else
        log "Docker Compose already installed"
    fi
    
    # Install Nginx
    if ! remote_exec "command -v nginx &>/dev/null"; then
        log "Installing Nginx..."
        remote_exec "sudo apt-get update && sudo apt-get install -y nginx" || {
            error "Nginx installation failed"
            exit 1
        }
    else
        log "Nginx already installed"
    fi
    
    # Start services
    remote_exec "sudo systemctl enable docker nginx"
    remote_exec "sudo systemctl start docker nginx"
    
    success "Remote environment setup completed"
}

deploy_application() {
    log "Deploying application..."
    
    # Create app directory on remote
    remote_exec "mkdir -p ~/$PROJECT_NAME"
    
    # Copy project files
    log "Transferring files to remote server..."
    remote_copy "." "~/$PROJECT_NAME/"
    
    # Stop existing container
    remote_exec "docker stop $CONTAINER_NAME 2>/dev/null || true"
    remote_exec "docker rm $CONTAINER_NAME 2>/dev/null || true"
    
    # Deploy based on project type
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log "Using Docker Compose..."
        remote_exec "cd ~/$PROJECT_NAME && docker-compose up -d --build"
    elif [ -f "Dockerfile" ]; then
        log "Using Dockerfile..."
        remote_exec "cd ~/$PROJECT_NAME && docker build -t $PROJECT_NAME . && docker run -d --name $CONTAINER_NAME -p $APP_PORT:$APP_PORT $PROJECT_NAME"
    else
        error "No Dockerfile or docker-compose.yml found"
        exit 1
    fi
    
    success "Application deployment completed"
}

setup_nginx() {
    log "Configuring Nginx reverse proxy..."
    
    # Create nginx config
    local nginx_conf="/tmp/${PROJECT_NAME}.conf"
    cat > "$nginx_conf" << EOF
server {
    listen 80;
    server_name $SERVER_IP;
    
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    # Copy and enable nginx config
    remote_copy "$nginx_conf" "/tmp/${PROJECT_NAME}.conf"
    remote_exec "sudo mv /tmp/${PROJECT_NAME}.conf /etc/nginx/sites-available/${PROJECT_NAME}"
    remote_exec "sudo ln -sf /etc/nginx/sites-available/${PROJECT_NAME} /etc/nginx/sites-enabled/${PROJECT_NAME}"
    remote_exec "sudo rm -f /etc/nginx/sites-enabled/default"
    
    # Test and reload nginx
    remote_exec "sudo nginx -t" || {
        error "Nginx configuration test failed"
        exit 1
    }
    remote_exec "sudo systemctl reload nginx"
    
    rm -f "$nginx_conf"
    success "Nginx configuration completed"
}

verify_deployment() {
    log "Verifying deployment..."
    
    # Check container status
    if remote_exec "docker ps | grep $CONTAINER_NAME"; then
        success "Container is running"
    else
        error "Container is not running"
        exit 1
    fi
    
    # Test application endpoint
    sleep 10  # Wait for app to start
    if remote_exec "curl -f -s -o /dev/null -w '%{http_code}' http://localhost:$APP_PORT" | grep -qE "200|301|302"; then
        success "Application is responding on port $APP_PORT"
    else
        warning "Application may not be fully started yet"
    fi
    
    # Test nginx proxy
    if curl -f -s -o /dev/null -w '%{http_code}' "http://$SERVER_IP" | grep -qE "200|301|302"; then
        success "Nginx proxy is working correctly"
    else
        warning "External access check inconclusive"
    fi
    
    success "Deployment verification completed"
}

cleanup() {
    log "Cleaning up..."
    unset PAT
    cd "$SCRIPT_DIR"
    success "Cleanup completed"
}

# Main execution
main() {
    echo "=== 🚀 Deployment Started at $TIMESTAMP ===" | tee -a "$LOG_FILE"
    
    check_dependencies
    collect_inputs
    setup_repository
    test_ssh_connection
    setup_remote_environment
    deploy_application
    setup_nginx
    verify_deployment
    cleanup
    
    echo ""
    success "=== 🎉 Deployment Completed Successfully! ==="
    log "Application URL: http://$SERVER_IP"
    log "Container Name: $CONTAINER_NAME"
    log "Log File: $LOG_FILE"
    echo ""
}

# Run main function
main "$@"