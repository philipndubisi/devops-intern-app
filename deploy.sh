#!/bin/bash
# ------------------------------------------------------------
# DevOps Intern Stage 1 Automated Deployment Script
# Robust, Idempotent, and Production-Grade
# ------------------------------------------------------------

readonly EXIT_SUCCESS=0
readonly EXIT_INPUT_ERROR=1
readonly EXIT_GIT_ERROR=2
readonly EXIT_SSH_ERROR=3
readonly EXIT_DOCKER_ERROR=4
readonly EXIT_NGINX_ERROR=5
readonly EXIT_VALIDATION_ERROR=6

set -e
trap 'error_exit "A command failed on line $LINENO"' ERR

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo -e "\033[1;32m[INFO]\033[0m $1" | tee -a "$LOG_FILE"
}

log_warn() {
  echo -e "\033[1;33m[WARN]\033[0m $1" | tee -a "$LOG_FILE"
}

error_exit() {
  echo -e "\033[1;31m[ERROR]\033[0m $1" | tee -a "$LOG_FILE"
  exit "${2:-1}"
}

if [[ "$1" == "--cleanup" ]]; then
    CLEANUP_ONLY=true
else
    CLEANUP_ONLY=false
fi

log "--- Collecting Deployment Parameters ---"

read -p "Enter GitHub Repository URL (HTTPS format): " REPO_URL
read -sp "Enter Personal Access Token (PAT) for cloning: " PAT
echo ""
read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter Remote Server Username (e.g. ubuntu): " REMOTE_USER
read -p "Enter Remote Server IP address: " REMOTE_IP
read -p "Enter SSH key path (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter Application Container Port (Internal Port, e.g. 5000): " APP_PORT

if [ -z "$REPO_URL" ] || [ -z "$PAT" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_IP" ] || [ -z "$SSH_KEY" ]; then
    error_exit "Missing required input parameters." $EXIT_INPUT_ERROR
fi

if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
    error_exit "Invalid port number. Must be between 1-65535." $EXIT_INPUT_ERROR
fi

SSH_KEY="${SSH_KEY/#\~/$HOME}"

if [ ! -f "$SSH_KEY" ]; then
    error_exit "SSH key file not found: $SSH_KEY" $EXIT_INPUT_ERROR
fi

if ! chmod 600 "$SSH_KEY" 2>/dev/null; then
    log_warn "Could not set SSH key permissions. Continuing anyway..."
fi
log "SSH key permissions set to 600"

if ! [[ "$REMOTE_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_warn "IP address format may be invalid: $REMOTE_IP"
fi

REPO_NAME=$(basename -s .git "$REPO_URL")
AUTH_REPO_URL=$(echo "$REPO_URL" | sed "s|https://|https://${PAT}@|")

REMOTE_APP_DIR_LOWER=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]')
REMOTE_APP_DIR="$REPO_NAME"

export REPO_URL BRANCH REMOTE_USER REMOTE_IP SSH_KEY APP_PORT REMOTE_APP_DIR_LOWER REMOTE_APP_DIR

log "All parameters validated successfully"

if $CLEANUP_ONLY; then
    log "--- Cleanup Mode: Removing remote resources ---"
    
    REMOTE_PATH="/home/${REMOTE_USER}/${REMOTE_APP_DIR}"
    
    ssh -t -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" \
    "REMOTE_APP_DIR_LOWER='${REMOTE_APP_DIR_LOWER}' REMOTE_USER='${REMOTE_USER}' REMOTE_APP_DIR='${REMOTE_APP_DIR}'" bash <<'EOF'
        set +e

        APP_IMAGE_TAG="app-${REMOTE_APP_DIR_LOWER}"
        NGINX_CONF_NAME="${REMOTE_APP_DIR_LOWER}.conf"
        NGINX_CONFIG_PATH="/etc/nginx/sites-available/$NGINX_CONF_NAME"
        NGINX_SYMLINK="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"

        echo "Stopping and removing container: $APP_IMAGE_TAG"
        docker stop $APP_IMAGE_TAG 2>/dev/null
        docker rm $APP_IMAGE_TAG 2>/dev/null
        docker rmi $APP_IMAGE_TAG 2>/dev/null

        echo "Removing Nginx configuration files..."
        sudo rm -f $NGINX_CONFIG_PATH
        sudo rm -f $NGINX_SYMLINK
        sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || true

        echo "Removing project directory..."
        rm -rf /home/${REMOTE_USER}/${REMOTE_APP_DIR}
        
        echo "Remote cleanup complete."
EOF
    
    if [ $? -eq 0 ]; then
        log "Cleanup completed successfully. Exiting."
    else
        log_warn "Cleanup encountered some errors but continued."
    fi
    exit $EXIT_SUCCESS
fi

log "Cloning repository: $REPO_NAME"

(
  if [ -d "$REPO_NAME" ]; then
    log "Repository exists. Refreshing to latest state..."
    cd "$REPO_NAME" || error_exit "Cannot change directory to $REPO_NAME." $EXIT_GIT_ERROR
    
    log "Resetting local repository to clean state..."
    git reset --hard HEAD 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    
    log "Fetching latest changes from origin..."
    git fetch origin 2>/dev/null || error_exit "Git fetch failed. Check network/PAT." $EXIT_GIT_ERROR
    
    log "Checking out branch: $BRANCH"
    git checkout "$BRANCH" 2>/dev/null || error_exit "Branch '$BRANCH' not found." $EXIT_GIT_ERROR
    git reset --hard "origin/$BRANCH" 2>/dev/null || error_exit "Failed to reset to origin/$BRANCH" $EXIT_GIT_ERROR
    
  else
    log "Cloning repository..."
    git clone "$AUTH_REPO_URL" "$REPO_NAME" 2>/dev/null || error_exit "Git clone failed. Check URL/PAT." $EXIT_GIT_ERROR
    cd "$REPO_NAME" || error_exit "Cannot change directory to $REPO_NAME." $EXIT_GIT_ERROR
    
    log "Checking out branch: $BRANCH"
    git checkout "$BRANCH" 2>/dev/null || error_exit "Branch '$BRANCH' not found in repository." $EXIT_GIT_ERROR
  fi

  log "Verifying Docker configuration files..."
  if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log "Docker configuration found"
  else
    error_exit "No Dockerfile or docker-compose.yml found in $REPO_NAME." $EXIT_VALIDATION_ERROR
  fi
)

unset PAT AUTH_REPO_URL
log "Repository cloned and verified"

log "Connecting to remote server at ${REMOTE_IP}..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_IP}" "echo 'SSH connection successful'" || error_exit "SSH connection failed." $EXIT_SSH_ERROR

log "Updating and installing Docker, Docker Compose, and Nginx (Idempotent)..."

ssh -T -t -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" <<EOF
  set -e
  sudo -v || exit 1 
  
  echo "Updating system packages..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release net-tools || exit 1

  if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get install -y docker.io || exit 1
  else
    echo "Docker already installed"
  fi

  if ! command -v docker-compose &> /dev/null; then
    echo "Installing Docker Compose..."
    sudo apt-get install -y docker-compose || exit 1
  else
    echo "Docker Compose already installed"
  fi
  
  if ! command -v nginx &> /dev/null; then
    echo "Installing Nginx..."
    sudo apt-get install -y nginx || exit 1
  else
    echo "Nginx already installed"
  fi
  
  sudo systemctl enable docker && sudo systemctl start docker || exit 1
  sudo systemctl enable nginx && sudo systemctl start nginx || exit 1
  
  if ! groups | grep -q docker; then
    echo "Adding user to docker group..."
    sudo usermod -aG docker \$USER || exit 1
    echo "Docker group membership updated."
  else
    echo "User already in docker group"
  fi
  
  if ! command -v sg &> /dev/null; then
    echo "Installing sg command..."
    sudo apt-get install -y shadow || true
  fi
  
  echo ""
  echo "=== Installed Versions ==="
  docker --version
  docker-compose --version
  nginx -v
  echo "=========================="
EOF

log "Remote environment prepared (Docker, Compose, Nginx running)."

log "Transferring project files to remote host..."

REMOTE_PATH="/home/${REMOTE_USER}/${REMOTE_APP_DIR}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" "mkdir -p $REMOTE_PATH"

log "Syncing files with rsync..."
rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" "$REPO_NAME/" "${REMOTE_USER}@${REMOTE_IP}:$REMOTE_PATH" \
  --exclude ".git" --exclude "*.log" || error_exit "File transfer failed." $EXIT_VALIDATION_ERROR

log "Verifying file transfer..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" \
  "[ -f $REMOTE_PATH/Dockerfile ] || [ -f $REMOTE_PATH/docker-compose.yml ]" || \
  error_exit "Files failed to transfer to remote server" $EXIT_VALIDATION_ERROR

log "Files transferred and verified"

log "Building, running, and configuring Nginx on remote server..."

ssh -T -t -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_IP}" \
"REMOTE_PATH='${REMOTE_PATH}' REMOTE_APP_DIR_LOWER='${REMOTE_APP_DIR_LOWER}' APP_PORT='${APP_PORT}'" bash <<'EOF'
  set -e
  cd $REMOTE_PATH
  
  APP_IMAGE_TAG="app-${REMOTE_APP_DIR_LOWER}"
  
  if sudo netstat -tuln | grep -q ":$APP_PORT "; then
    echo "Port $APP_PORT is already in use. Cleaning up..."
  fi
  
  echo "Cleaning up old container and image ($APP_IMAGE_TAG)..."
  if command -v sg &> /dev/null && sg docker -c "docker ps" &> /dev/null; then
    DOCKER_CMD="sg docker -c"
  else
    echo "Using sudo for docker commands..."
    DOCKER_CMD="sudo"
  fi
  
  $DOCKER_CMD "docker stop $APP_IMAGE_TAG" 2>/dev/null || true
  $DOCKER_CMD "docker rm $APP_IMAGE_TAG" 2>/dev/null || true
  
  if $DOCKER_CMD "docker images -q $APP_IMAGE_TAG" 2>/dev/null | grep -q .; then
    echo "Removing existing Docker image: $APP_IMAGE_TAG"
    $DOCKER_CMD "docker rmi $APP_IMAGE_TAG" 2>/dev/null || true
  fi
  
  echo "Pruning dangling images..."
  $DOCKER_CMD "docker image prune -f" 2>/dev/null || true

  echo "Building new Docker image: $APP_IMAGE_TAG"
  $DOCKER_CMD "docker build -t $APP_IMAGE_TAG ." || exit 1

  echo "Running new container, mapping to 127.0.0.1:$APP_PORT:$APP_PORT..."
  $DOCKER_CMD "docker run -d --restart=always -p 127.0.0.1:$APP_PORT:$APP_PORT --name $APP_IMAGE_TAG $APP_IMAGE_TAG" || exit 1

  echo "Checking container status..."
  echo "Waiting for container to be healthy..."
  for i in {1..45}; do
    if $DOCKER_CMD "docker ps" | grep -q $APP_IMAGE_TAG; then
      echo "Container is running"
      break
    fi
    if [ $i -eq 45 ]; then
      echo "Container failed to start after 45 seconds"
      echo "Container logs:"
      $DOCKER_CMD "docker logs $APP_IMAGE_TAG"
      exit 1
    fi
    sleep 1
  done

  echo "Setting up Nginx reverse proxy configuration..."
  
  NGINX_CONF_NAME="${REMOTE_APP_DIR_LOWER}.conf"
  NGINX_CONFIG_PATH="/etc/nginx/sites-available/$NGINX_CONF_NAME"
  NGINX_SYMLINK="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"

  sudo bash -c "cat > $NGINX_CONFIG_PATH" <<NGINXCONF
server {
    listen 80;
    server_name _; 

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

  sudo ln -sf $NGINX_CONFIG_PATH $NGINX_SYMLINK
  sudo rm -f /etc/nginx/sites-enabled/default

  echo "Testing Nginx configuration..."
  if sudo nginx -t; then
    echo "Nginx configuration valid"
    sudo systemctl reload nginx || exit 1
  else
    echo "Nginx configuration test failed"
    exit 1
  fi
  
  echo "Running final service checks..."
  sudo systemctl is-active docker >/dev/null || (echo "Docker not active" && exit 1)
  sudo systemctl is-active nginx >/dev/null || (echo "Nginx not active" && exit 1)
  echo "Docker and Nginx services are active"

  echo "Testing app via Nginx (http://localhost)..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
  if [ "$HTTP_CODE" = "200" ]; then
      echo "Local Nginx reverse proxy test passed (200 OK)."
  else
      echo "Nginx test returned HTTP $HTTP_CODE"
  fi
  
  echo "Showing container logs (last 10 lines):"
  $DOCKER_CMD "docker logs --tail 10 $APP_IMAGE_TAG"
EOF

log "Deployment completed successfully on remote server"

log "Testing deployment from local machine..."
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${REMOTE_IP}" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log "Remote access test passed (200 OK)."
else
    log_warn "Remote access test returned HTTP $HTTP_CODE. Check firewall/security groups."
    log_warn "If this is expected (firewall rules), the deployment itself was successful."
fi

log "=========================================="
log "Deployment Complete"
log "Visit: http://${REMOTE_IP} to view your app"
log "Log file: $LOG_FILE"
log "=========================================="

exit $EXIT_SUCCESS
