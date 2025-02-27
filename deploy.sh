#!/bin/bash

# Common Env Vars
SWAP_SIZE="1G"                # Swap size of 1GB
DOMAIN_NAME="kaabbarsha.com"  # replace with your own
EMAIL="kaabteacher@gmail.com" # replace with your own

# Function to deploy an app
deploy_app() {
	local APP_NAME=$1
	local REPO_URL=$2
	local PORT=$3
	local SUBDOMAIN=$4

	# App-specific variables
	local POSTGRES_USER="${APP_NAME}_user"
	local POSTGRES_PASSWORD=$(openssl rand -base64 12) # Generate a random password
	local POSTGRES_DB="${APP_NAME}_db"
	local SECRET_KEY="${APP_NAME}-secret-$(openssl rand -hex 8)"
	local NEXT_PUBLIC_SAFE_KEY="${APP_NAME}-safe-$(openssl rand -hex 8)"

	# App directory
	local APP_DIR=~/${APP_NAME}

	echo "Deploying $APP_NAME on port $PORT with subdomain $SUBDOMAIN..."

	# Clone the Git repository
	if [ -d "$APP_DIR" ]; then
		echo "Directory $APP_DIR already exists. Pulling latest changes..."
		cd $APP_DIR && git pull
	else
		echo "Cloning repository from $REPO_URL..."
		git clone $REPO_URL $APP_DIR
		cd $APP_DIR
	fi

	# For Docker internal communication ("db" is the name of Postgres container in docker-compose)
	local DATABASE_URL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@db:5432/$POSTGRES_DB"

	# For external tools (like Drizzle Studio)
	local DATABASE_URL_EXTERNAL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:${PORT}32/$POSTGRES_DB"

	# Create the .env file inside the app directory
	echo "POSTGRES_USER=$POSTGRES_USER" >"$APP_DIR/.env"
	echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >>"$APP_DIR/.env"
	echo "POSTGRES_DB=$POSTGRES_DB" >>"$APP_DIR/.env"
	echo "DATABASE_URL=$DATABASE_URL" >>"$APP_DIR/.env"
	echo "DATABASE_URL_EXTERNAL=$DATABASE_URL_EXTERNAL" >>"$APP_DIR/.env"
	echo "PORT=$PORT" >>"$APP_DIR/.env"
	echo "SECRET_KEY=$SECRET_KEY" >>"$APP_DIR/.env"
	echo "NEXT_PUBLIC_SAFE_KEY=$NEXT_PUBLIC_SAFE_KEY" >>"$APP_DIR/.env"

	# Create/update docker-compose.yml for this app
	cat >"$APP_DIR/docker-compose.yml" <<EOL
version: '3'
services:
  web:
    build: .
    restart: always
    ports:
      - "$PORT:3000"
    environment:
      - NODE_ENV=production
      - PORT=3000
      - DATABASE_URL=\${DATABASE_URL}
      - SECRET_KEY=\${SECRET_KEY}
      - NEXT_PUBLIC_SAFE_KEY=\${NEXT_PUBLIC_SAFE_KEY}
    depends_on:
      - db
    networks:
      - ${APP_NAME}_network

  db:
    image: postgres:latest
    restart: always
    ports:
      - "${PORT}32:5432"
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - ${APP_NAME}_postgres_data:/var/lib/postgresql/data
    networks:
      - ${APP_NAME}_network

networks:
  ${APP_NAME}_network:
    driver: bridge

volumes:
  ${APP_NAME}_postgres_data:
EOL

	# Create Nginx config for this app
	sudo cat >/etc/nginx/sites-available/${APP_NAME} <<EOL
# Define rate limiting zone for this app
limit_req_zone \$binary_remote_addr zone=${APP_NAME}_limit:10m rate=10r/s;

server {
    listen 80;
    server_name ${SUBDOMAIN}.${DOMAIN_NAME};

    # Redirect all HTTP requests to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${SUBDOMAIN}.${DOMAIN_NAME};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Apply rate limiting to all locations
    limit_req zone=${APP_NAME}_limit burst=20 nodelay;

    location / {
        proxy_pass http://localhost:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;

        # Disable buffering for streaming support
        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
    }
}
EOL

	# Create symbolic link if it doesn't already exist
	sudo ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/${APP_NAME}

	# Build and run the Docker containers
	cd $APP_DIR
	sudo docker-compose up --build -d

	echo "$APP_NAME deployed successfully at https://${SUBDOMAIN}.${DOMAIN_NAME}"
}

# Update package list and upgrade existing packages
sudo apt update && sudo apt upgrade -y

# Add Swap Space if not already added
if [ ! -f /swapfile ]; then
	echo "Adding swap space..."
	sudo fallocate -l $SWAP_SIZE /swapfile
	sudo chmod 600 /swapfile
	sudo mkswap /swapfile
	sudo swapon /swapfile

	# Make swap permanent
	echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# Install Docker if not already installed
if ! command -v docker &>/dev/null; then
	echo "Installing Docker..."
	sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
	sudo apt update
	sudo apt install docker-ce -y

	# Ensure Docker starts on boot
	sudo systemctl enable docker
	sudo systemctl start docker
fi

# Install Docker Compose if not already installed
if ! command -v docker-compose &>/dev/null; then
	echo "Installing Docker Compose..."
	sudo rm -f /usr/local/bin/docker-compose
	sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
	sudo chmod +x /usr/local/bin/docker-compose
	sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

	# Verify Docker Compose installation
	docker-compose --version
	if [ $? -ne 0 ]; then
		echo "Docker Compose installation failed. Exiting."
		exit 1
	fi
fi

# Install Nginx if not already installed
if ! command -v nginx &>/dev/null; then
	echo "Installing Nginx..."
	sudo apt install nginx -y
fi

# Stop Nginx temporarily to allow Certbot to run in standalone mode
sudo systemctl stop nginx

# Install Certbot and get wildcard certificate
if ! command -v certbot &>/dev/null; then
	echo "Installing Certbot..."
	sudo apt install certbot -y
fi

# Obtain/renew SSL certificate for the domain
sudo certbot certonly --standalone -d $DOMAIN_NAME -d *.$DOMAIN_NAME --non-interactive --agree-tos -m $EMAIL

# Ensure SSL files exist or generate them
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
	sudo wget https://raw.githubusercontent.com/certbot/certbot/main/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -P /etc/letsencrypt/
fi

if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
	sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
fi

# Deploy apps (APP_NAME, REPO_URL, PORT, SUBDOMAIN)
deploy_app "myapp" "https://github.com/asimqasmi/selfhostnext.git" 3000 "app"
# Add more apps as needed by uncommenting and modifying the line below:
# deploy_app "secondapp" "https://github.com/yourusername/secondapp.git" 3001 "second"
# deploy_app "thirdapp" "https://github.com/yourusername/thirdapp.git" 3002 "third"

# Restart Nginx to apply all configurations
sudo systemctl restart nginx

echo "All applications deployed successfully!"

# Output final message
echo "Deployment complete. Your Next.js app and PostgreSQL database are now running. 
Next.js is available at https://$DOMAIN_NAME, and the PostgreSQL database is accessible from the web service.

The .env file has been created with the following values:
- POSTGRES_USER
- POSTGRES_PASSWORD (randomly generated)
- POSTGRES_DB
- DATABASE_URL
- DATABASE_URL_EXTERNAL
- SECRET_KEY
- NEXT_PUBLIC_SAFE_KEY"
