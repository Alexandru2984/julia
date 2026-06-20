limit_req_zone $binary_remote_addr zone=julia_general:10m rate=120r/m;
limit_req_zone $binary_remote_addr zone=julia_benchmark_api:10m rate=12r/m;
# Job polling runs at ~2 req/s per client (pollJob in app.js), which sits right
# on top of the general limit. Give it its own, more generous bucket so a single
# active user does not trip 429 while waiting for a result.
limit_req_zone $binary_remote_addr zone=julia_jobs_poll:10m rate=240r/m;

server {
    server_name julia.micutu.com;

    # Only accept traffic that actually came through Cloudflare. $from_cloudflare_origin
    # is set in conf.d/cloudflare-origin-guard.conf from the real TCP peer. Without
    # this, anyone who learns the origin IP can hit nginx directly and bypass the
    # Cloudflare WAF, rate limiting, and bot protection (matches the other vhosts).
    if ($from_cloudflare_origin = 0) {
        return 403;
    }

    client_max_body_size 16k;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; upgrade-insecure-requests" always;

    access_log /var/log/nginx/julia.micutu.com.access.log;
    error_log /var/log/nginx/julia.micutu.com.error.log;

    location /api/benchmark/ {
        limit_req zone=julia_benchmark_api burst=4 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8095;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    location /api/jobs/ {
        limit_req zone=julia_jobs_poll burst=20 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8095;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    location / {
        limit_req zone=julia_general burst=40 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8095;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    listen [::]:443 ssl; # managed by Certbot
    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/julia.micutu.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/julia.micutu.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}

server {
    if ($host = julia.micutu.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot

    listen 80;
    listen [::]:80;
    server_name julia.micutu.com;
    return 404; # managed by Certbot
}
