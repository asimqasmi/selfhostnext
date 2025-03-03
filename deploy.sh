#!/bin/bash

# Env Vars
POSTGRES_USER="asim"
POSTGRES_PASSWORD=$(openssl rand -base64 12) # Generate a random 12-character password
POSTGRES_DB="mydatabase"
SECRET_KEY="my-secret-25"              # for the demo app
NEXT_PUBLIC_SAFE_KEY="safe-key"        # for the demo app
DOMAIN_NAME="kaabbarsha.com"           # replace with your own
EMAIL="kaabteacher@gmail.com"          # replace with your own
SUBDOMAINS=("app" "api" "admin" "lrc") # List your desired subdomains here

# Script Vars
REPO_URL="https://github.com/asimqasmi/selfhostnext.git"
APP_DIR=~/myapp
SWAP_SIZE="1G" # Swap size of 1GB

# Update package list and upgrade existing packages
sudo apt update && sudo apt upgrade -y

# Add Swap Space
echo "Adding swap space..."
sudo fallocate -l $SWAP_SIZE /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make swap permanent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Install Docker
sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
sudo apt update
sudo apt install docker-ce -y

# Install Docker Compose
sudo rm -f /usr/local/bin/docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

# Wait for the file to be fully downloaded before proceeding
if [ ! -f /usr/local/bin/docker-compose ]; then
	echo "Docker Compose download failed. Exiting."
	exit 1
fi

sudo chmod +x /usr/local/bin/docker-compose

# Ensure Docker Compose is executable and in path
sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Verify Docker Compose installation
docker-compose --version
if [ $? -ne 0 ]; then
	echo "Docker Compose installation failed. Exiting."
	exit 1
fi

# Ensure Docker starts on boot and start Docker service
sudo systemctl enable docker
sudo systemctl start docker

# Clone the Git repository
if [ -d "$APP_DIR" ]; then
	echo "Directory $APP_DIR already exists. Pulling latest changes..."
	cd $APP_DIR && git pull
else
	echo "Cloning repository from $REPO_URL..."
	git clone $REPO_URL $APP_DIR
	cd $APP_DIR
fi

# For Docker internal communication ("db" is the name of Postgres container)
DATABASE_URL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@db:5432/$POSTGRES_DB"

# For external tools (like Drizzle Studio)
DATABASE_URL_EXTERNAL="postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:5432/$POSTGRES_DB"

# Create the .env file inside the app directory (~/myapp/.env)
echo "POSTGRES_USER=$POSTGRES_USER" >"$APP_DIR/.env"
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >>"$APP_DIR/.env"
echo "POSTGRES_DB=$POSTGRES_DB" >>"$APP_DIR/.env"
echo "DATABASE_URL=$DATABASE_URL" >>"$APP_DIR/.env"
echo "DATABASE_URL_EXTERNAL=$DATABASE_URL_EXTERNAL" >>"$APP_DIR/.env"

# These are just for the demo of env vars
echo "SECRET_KEY=$SECRET_KEY" >>"$APP_DIR/.env"
echo "NEXT_PUBLIC_SAFE_KEY=$NEXT_PUBLIC_SAFE_KEY" >>"$APP_DIR/.env"

# Install Nginx
sudo apt install nginx -y

# Remove old Nginx config (if it exists)
sudo rm -f /etc/nginx/sites-available/myapp
sudo rm -f /etc/nginx/sites-enabled/myapp

# Stop Nginx temporarily to allow Certbot to run in standalone mode
sudo systemctl stop nginx

# Obtain SSL certificate using Certbot standalone mode
sudo apt install certbot -y

# Replace the existing Certbot command with this
DOMAIN_ARGS="-d $DOMAIN_NAME"
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
	DOMAIN_ARGS="$DOMAIN_ARGS -d $SUBDOMAIN.$DOMAIN_NAME"
done

sudo certbot certonly --standalone $DOMAIN_ARGS --non-interactive --agree-tos -m $EMAIL

# sudo certbot certonly --standalone -d $DOMAIN_NAME --non-interactive --agree-tos -m $EMAIL

# Ensure SSL files exist or generate them
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
	sudo wget https://raw.githubusercontent.com/certbot/certbot/main/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -P /etc/letsencrypt/
fi

if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
	sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
fi

# Create Nginx config with reverse proxy, SSL support, rate limiting, and streaming support
sudo cat >/etc/nginx/sites-available/myapp <<EOL
limit_req_zone \$binary_remote_addr zone=mylimit:10m rate=10r/s;

server {
    listen 80;
    server_name $DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    limit_req zone=mylimit burst=20 nodelay;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
    }
}
EOL

# Create subdomain configs
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
	# Define the port based on subdomain (you might want to customize this logic)
	case $SUBDOMAIN in
	"app")
		PORT=3001
		;;
	"api")
		PORT=3002
		;;
	"admin")
		PORT=3003
		;;
	"lrc")
		PORT=3004
		;;
	*)
		PORT=3000
		;;
	esac

	sudo cat >/etc/nginx/sites-available/$SUBDOMAIN <<EOL
server {
    listen 80;
    server_name $SUBDOMAIN.$DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $SUBDOMAIN.$DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    limit_req zone=mylimit burst=20 nodelay;

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
    }
}
EOL

	# Create symbolic link for each subdomain config
	sudo ln -sf /etc/nginx/sites-available/$SUBDOMAIN /etc/nginx/sites-enabled/$SUBDOMAIN
done

# Create symbolic link if it doesn't already exist
sudo ln -s /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/myapp

# Update docker-compose.yml to expose additional ports for subdomains
echo "Updating docker-compose.yml to expose ports for subdomains..."
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# Backup the original docker-compose file
cp $COMPOSE_FILE ${COMPOSE_FILE}.bak

# Port mapping adjustments to add (assumes there's already a '- "3000:3000"' line)
sed -i '/- "3000:3000"/a \      - "3001:3001"\n      - "3002:3002"\n      - "3003:3003"\n      - "3004:3004"' $COMPOSE_FILE

# Restart Nginx to apply the new configuration
sudo systemctl restart nginx

# Build and run the Docker containers from the app directory (~/myapp)
cd $APP_DIR
sudo docker-compose up --build -d

# Check if Docker Compose started correctly
if ! sudo docker-compose ps | grep "Up"; then
	echo "Docker containers failed to start. Check logs with 'docker-compose logs'."
	exit 1
fi

# Output final message
echo "Deployment complete. Your Next.js app and PostgreSQL database are now running. 
Main domain is available at https://$DOMAIN_NAME

Subdomains are configured as follows:
- https://app.$DOMAIN_NAME (port 3001)
- https://api.$DOMAIN_NAME (port 3002)
- https://admin.$DOMAIN_NAME (port 3003)
- https://lrc.$DOMAIN_NAME (port 3004)

The .env file has been created with the following values:
- POSTGRES_USER
- POSTGRES_PASSWORD (randomly generated)
- POSTGRES_DB
- DATABASE_URL
- DATABASE_URL_EXTERNAL
- SECRET_KEY
- NEXT_PUBLIC_SAFE_KEY
