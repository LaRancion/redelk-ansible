#!/bin/bash
#
# Part of RedELK
# Script to bootstrap certbot tls certificates for nginx
#
# Authors:
# - Lorenzo Bernardi (@fastlorenzo)
# - Outflank B.V. / Marc Smeets
#

rsa_key_size=4096
data_path="./mounts/certbot"
email="$(cat ./mounts/redelk-config/etc/redelk/config.json | jq -r .redelkserver_letsencrypt.le_email)" # Adding a valid address is strongly recommended
staging="$(cat ./mounts/redelk-config/etc/redelk/config.json | jq -r .redelkserver_letsencrypt.staging)"  # Set to 1 if you're testing your setup to avoid hitting request limits

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

if [ ${#} -eq 2 ] && [[ -f $1  ]]; then
  compose_file=$1
  domain=$2
else
  echo "[X] Error: 1st parameter should be input file for docker-compose, 2nd the domain name. Exiting."
  exit 1
fi

# if [ -d "$data_path" ]; then
#   read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
#   if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
#     exit
#   fi
# fi

if [ -f "$data_path/conf/live/$domain/privkey.pem" ]; then
  echo "Existing data found for $domain, skipping"
  exit 0
fi

echo "### Creating dummy certificate for $domain ..."
path="/etc/letsencrypt/live/$domain"
mkdir -p "$data_path/conf/live/$domain"
docker-compose -f $compose_file run -T --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 365\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=${domain}'" certbot
echo

echo "### Starting nginx ..."
docker-compose -f $compose_file down
docker-compose -f $compose_file up -d nginx
echo

# Wait for nginx to actually be ready to serve HTTP on port 80
# (docker-compose up -d returns immediately, but nginx needs time to start,
#  run envsubst on templates, and bind the port — especially on first deploy
#  when images are still being pulled)
echo "### Waiting for nginx to be ready..."
nginx_ready=false
for i in $(seq 1 60); do
  if docker-compose -f $compose_file exec -T nginx nginx -t >/dev/null 2>&1 \
     && curl -s -o /dev/null -w "%{http_code}" http://localhost:80/ 2>/dev/null | grep -qE "^(200|301|302|401|403)$"; then
    echo "nginx is ready (attempt $i)"
    nginx_ready=true
    break
  fi
  echo "  nginx not ready yet, retrying in 3s (attempt $i/60)..."
  sleep 3
done

if [ "$nginx_ready" = false ]; then
  echo "[X] nginx did not become ready within 180s. Let's Encrypt challenge will likely fail." >&2
fi
echo

echo "### Requesting Let's Encrypt certificate for $domain ..."

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

echo "### Removing dummy certificate folder"
rm -Rf "$data_path/conf/live/$domain"

docker-compose -f $compose_file run -T --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    -d $domain \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal -n" certbot
echo

echo "### Reloading nginx ..."
docker-compose -f $compose_file exec nginx nginx -s reload