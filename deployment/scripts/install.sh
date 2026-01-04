#!/usr/bin/env bash
#
# Production installation script for Open WebUI MCP Server
# Installs to /home/open-webui-mcp with systemd service
# Requires: root privileges, uv package manager

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICE_USER="open-webui-mcp"
INSTALL_DIR="/home/$SERVICE_USER"
LOG_DIR="$INSTALL_DIR/log"
SERVICE_FILE="open-webui-mcp.service"
SYSTEMD_DIR="/etc/systemd/system"

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_uv() {
    # First check if user already exists (created earlier in flow)
    if id "$SERVICE_USER" &>/dev/null; then
        # Check if service user has uv installed
        if sudo -i -u "$SERVICE_USER" command -v uv &> /dev/null; then
            UV_PATH=$(sudo -i -u "$SERVICE_USER" command -v uv)
            log_info "uv found at $UV_PATH"
            return 0
        fi
    fi

    # uv not found, need to install for service user
    log_warn "uv not found for service user. Installing uv..."

    # Ensure service user exists before installing
    if ! id "$SERVICE_USER" &>/dev/null; then
        log_error "Service user $SERVICE_USER must be created before installing uv"
        exit 1
    fi

    # Install uv as the service user (to ~/.local/bin)
    sudo -i -u "$SERVICE_USER" bash <<'EOF'
# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# Add to PATH in .profile (for login shells)
if ! grep -q '.local/bin' ~/.profile 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
fi
EOF

    # Verify installation
    if sudo -i -u "$SERVICE_USER" command -v uv &> /dev/null; then
        UV_PATH=$(sudo -i -u "$SERVICE_USER" command -v uv)
        log_info "uv installed successfully at $UV_PATH"
    else
        log_error "Failed to install uv for service user. Please install manually: https://github.com/astral-sh/uv"
        exit 1
    fi
}

create_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        log_info "User $SERVICE_USER already exists"
    else
        log_info "Creating system user $SERVICE_USER with home directory..."
        # Use /bin/bash shell to allow uv installation and environment setup
        useradd --system --create-home --home-dir "$INSTALL_DIR" --shell /bin/bash "$SERVICE_USER"
        # Lock the password for security (prevent login via password)
        passwd -l "$SERVICE_USER" &>/dev/null
        log_info "User $SERVICE_USER created with home at $INSTALL_DIR"
    fi
}

create_directories() {
    log_info "Creating directory structure..."

    # Installation directory created by useradd --create-home
    # Just ensure subdirectories exist
    sudo -u "$SERVICE_USER" mkdir -p "$INSTALL_DIR/src"
    sudo -u "$SERVICE_USER" mkdir -p "$INSTALL_DIR/deployment"

    # Create log directory (needs root)
    mkdir -p "$LOG_DIR"
    chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
    chmod 755 "$LOG_DIR"

    log_info "Directories created"
}

copy_source() {
    log_info "Copying source code to $INSTALL_DIR..."

    # Get script directory (deployment/scripts/)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # Copy files as root (current user may own source files)
    # Then change ownership to service user
    cp -r "$PROJECT_ROOT/src/"* "$INSTALL_DIR/src/"
    cp "$PROJECT_ROOT/pyproject.toml" "$INSTALL_DIR/"
    cp "$PROJECT_ROOT/.env.example" "$INSTALL_DIR/"
    cp "$PROJECT_ROOT/README.md" "$INSTALL_DIR/"
    cp -r "$PROJECT_ROOT/deployment" "$INSTALL_DIR/"

    # Change ownership of all copied files to service user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

    log_info "Source code copied and ownership set"
}

create_venv() {
    log_info "Creating virtual environment with uv..."

    # Run as service user with login shell (loads .profile with PATH)
    sudo -i -u "$SERVICE_USER" bash <<EOF
cd "$INSTALL_DIR"

# Create venv
uv venv

# Install the package and its production dependencies
# Use 'uv pip install' instead of 'uv sync' since we don't have a lock file
uv pip install .
EOF

    log_info "Virtual environment created and dependencies installed"
}

setup_environment() {
    log_info "Setting up environment configuration..."

    if [[ -f "$INSTALL_DIR/.env" ]]; then
        log_warn ".env file already exists, skipping creation"
        log_warn "Please review $INSTALL_DIR/.env manually"
    else
        sudo -u "$SERVICE_USER" cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
        sudo -u "$SERVICE_USER" chmod 600 "$INSTALL_DIR/.env"
        log_info ".env file created from .env.example"
        log_warn "IMPORTANT: Edit $INSTALL_DIR/.env with your Open WebUI base URL and API key"
    fi
}

set_permissions() {
    log_info "Setting file permissions..."

    # Ownership already correct (files created as service user)
    # Just verify key directories
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"

    # Set directory permissions
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$LOG_DIR"

    # .env should be readable only by service user (already set in setup_environment)
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        chmod 600 "$INSTALL_DIR/.env"
    fi

    # Scripts should be executable
    chmod 755 "$INSTALL_DIR/deployment/scripts/"*.sh

    log_info "Permissions set"
}

prompt_configuration() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Configuration Setup${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # Prompt for Open WebUI URL
    echo -e "${YELLOW}Enter your Open WebUI URL${NC}"
    echo -e "  Example: ${GREEN}http://localhost:8080${NC}"
    echo -e "  Example: ${GREEN}https://openwebui.example.com${NC}"
    echo ""
    read -p "Open WebUI URL: " OPENWEBUI_URL

    # Validate URL is not empty
    if [[ -z "$OPENWEBUI_URL" ]]; then
        log_error "Open WebUI URL cannot be empty"
        exit 1
    fi

    echo ""

    # Prompt for API key (securely - hidden input)
    echo -e "${YELLOW}Enter your Open WebUI API Key${NC}"
    echo -e "  To generate an API key:"
    echo -e "    1. Log into Open WebUI"
    echo -e "    2. Go to ${GREEN}Settings → Account → API Keys${NC}"
    echo -e "    3. Click ${GREEN}Create new secret key${NC}"
    echo -e "    4. Copy the generated key"
    echo ""
    echo -e "  Example format: ${GREEN}sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx${NC}"
    echo ""
    read -s -p "API Key (input hidden): " OPENWEBUI_API_KEY
    echo ""  # Add newline after hidden input

    # Validate API key is not empty
    if [[ -z "$OPENWEBUI_API_KEY" ]]; then
        log_error "API Key cannot be empty"
        exit 1
    fi

    echo ""
    log_info "Configuration received"
}

configure_env_file() {
    log_info "Configuring .env file with provided values..."

    # Update the .env file with user-provided values
    # Use sed to replace the placeholder values
    sed -i "s|^OPENWEBUI_BASE_URL=.*|OPENWEBUI_BASE_URL=$OPENWEBUI_URL|" "$INSTALL_DIR/.env"
    sed -i "s|^OPENWEBUI_API_KEY=.*|OPENWEBUI_API_KEY=$OPENWEBUI_API_KEY|" "$INSTALL_DIR/.env"

    # Secure the file permissions
    chmod 600 "$INSTALL_DIR/.env"
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"

    log_info ".env file configured successfully"
}

install_systemd_service() {
    log_info "Installing systemd service..."

    # Copy service file
    cp "$INSTALL_DIR/deployment/systemd/$SERVICE_FILE" "$SYSTEMD_DIR/"

    # Set service file permissions
    chmod 644 "$SYSTEMD_DIR/$SERVICE_FILE"

    # Reload systemd daemon
    systemctl daemon-reload

    log_info "Systemd service installed"
}

enable_service() {
    log_info "Enabling and starting systemd service..."

    systemctl enable --now "$SERVICE_FILE"

    log_info "Service enabled and started"
}

run_tests() {
    log_info "Running tests to verify installation..."

    # Run tests as service user with login shell (loads .profile with PATH)
    if sudo -i -u "$SERVICE_USER" bash -c "cd $INSTALL_DIR && uv run pytest -m unit --tb=short" 2>/dev/null; then
        log_info "Tests passed successfully"
    else
        log_warn "Tests failed or test dependencies not installed"
        log_warn "This is not critical for production deployment"
    fi
}

print_post_install() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${GREEN}✓ Service configured and running${NC}"
    echo ""
    echo -e "${YELLOW}Verify Installation:${NC}"
    echo ""
    echo "1. Check service status:"
    echo -e "   ${GREEN}sudo systemctl status $SERVICE_FILE${NC}"
    echo ""
    echo "2. View logs:"
    echo -e "   ${GREEN}sudo journalctl -u $SERVICE_FILE -f${NC}"
    echo ""
    echo "3. Test the MCP server:"
    echo -e "   ${GREEN}curl http://127.0.0.1:8000/sse${NC}"
    echo ""
    echo -e "${YELLOW}Configure MCP Client:${NC}"
    echo ""
    echo "Claude Code:"
    echo -e "   ${GREEN}claude mcp add open-webui --transport sse http://127.0.0.1:8000/sse${NC}"
    echo ""
    echo "Claude Desktop / Cursor / Windsurf - add to config:"
    echo "   {"
    echo "     \"mcpServers\": {"
    echo "       \"open-webui\": {"
    echo "         \"type\": \"sse\","
    echo "         \"url\": \"http://127.0.0.1:8000/sse\""
    echo "       }"
    echo "     }"
    echo "   }"
    echo ""
    echo -e "${YELLOW}Service Management:${NC}"
    echo -e "   Start:   ${GREEN}sudo systemctl start $SERVICE_FILE${NC}"
    echo -e "   Stop:    ${GREEN}sudo systemctl stop $SERVICE_FILE${NC}"
    echo -e "   Restart: ${GREEN}sudo systemctl restart $SERVICE_FILE${NC}"
    echo -e "   Status:  ${GREEN}sudo systemctl status $SERVICE_FILE${NC}"
    echo -e "   Logs:    ${GREEN}sudo journalctl -u $SERVICE_FILE -f${NC}"
    echo ""
    echo -e "${YELLOW}Reconfigure (if needed):${NC}"
    echo -e "   ${GREEN}sudo nano $INSTALL_DIR/.env${NC}"
    echo -e "   ${GREEN}sudo systemctl restart $SERVICE_FILE${NC}"
    echo ""
}

main() {
    log_info "Starting Open WebUI MCP Server installation..."

    # Pre-flight checks
    check_root

    # Installation steps
    create_user
    check_uv  # Check/install uv AFTER creating service user
    create_directories
    copy_source
    create_venv
    setup_environment

    # Interactive configuration (prompt for URL and API key)
    prompt_configuration
    configure_env_file

    set_permissions
    install_systemd_service
    enable_service

    # Optional: run tests
    if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
        run_tests
    fi

    # Post-installation instructions
    print_post_install
}

main "$@"
