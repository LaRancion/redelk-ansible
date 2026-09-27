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

# Wait for nginx to actually be ready to serve HTTP on port 80.
# docker-compose up -d returns immediately, but nginx needs time to start,
# run envsubst on templates, and bind the port — especially on first deploy
# when images are still being pulled.
echo "### Waiting for nginx to be ready..."
nginx_ready=false
for i in $(seq 1 60); do
  # Check if the container is running at all
  container_state=$(docker-compose -f $compose_file ps nginx 2>/dev/null | grep -c 'Up')
  if [ "$container_state" -eq 0 ]; then
    echo "  [attempt $i/60] nginx container not running yet. Logs:"
    docker-compose -f $compose_file logs --tail=5 nginx 2>&1 | sed 's/^/    /'
    sleep 3
    continue
  fi

  # Check if nginx config is valid
  nginx -t 2>/dev/null
  nginx_config_ok=$?
  if [ "$nginx_config_ok" -ne 0 ]; then
    echo "  [attempt $i/60] nginx config test failed:"
    docker-compose -f $compose_file exec -T nginx nginx -t 2>&1 | sed 's/^/    /'
    sleep 3
    continue
  fi

  # Check if port 80 is actually serving
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80/ 2>/dev/null)
  if echo "$http_code" | grep -qE "^(200|301|302|401|403)$"; then
    echo "nginx is ready (attempt $i, HTTP $http_code)"
    nginx_ready=true
    break
  fi
  echo "  [attempt $i/60] nginx running but port 80 not ready (HTTP code: ${http_code:-none})"
  sleep 3
done

if [ "$nginx_ready" = false ]; then
  echo "[X] nginx did not become ready within 180s. Let's Encrypt challenge will likely fail." >&2
  echo "[X] Last 20 nginx log lines:"
  docker-compose -f $compose_file logs --tail=20 nginx 2>&1 | sed 's/^/    /' >&2
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
CERTBOT_RC=$?
echo

if [ "$CERTBOT_RC" -ne 0 ]; then
  echo "[X] certbot failed with exit code $CERTBOT_RC" >&2
  echo "[X] Let's Encrypt challenge failed. Common causes:" >&2
  echo "    - Port 80 not reachable from the internet (firewall/NSG)" >&2
  echo "    - DNS not resolving $domain to this host" >&2
  echo "    - Rate limit hit (try staging mode: le_staging: 1)" >&2
  echo "    - nginx not serving /.well-known/acme-challenge/ correctly" >&2
  # Recreate the directory so the fallback cert task can write to it
  mkdir -p "$data_path/conf/live/$domain"
  exit $CERTBOT_RC
fi

echo "### Reloading nginx ..."
docker-compose -f $compose_file exec -T nginx nginx -s reload