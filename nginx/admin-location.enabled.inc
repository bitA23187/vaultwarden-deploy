# Maintenance policy: temporary enable /admin.
# Switch back to admin-location.disabled.inc after maintenance.
location /admin {
    limit_req zone=admin_limit burst=3 nodelay;

    proxy_pass         http://vaultwarden:80;
    proxy_set_header   Host                $host;
    proxy_set_header   X-Real-IP           $remote_addr;
    proxy_set_header   X-Forwarded-For     $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto   $scheme;
    proxy_set_header   X-Forwarded-Host    $host;
    proxy_set_header   X-Forwarded-Port    $server_port;
    proxy_read_timeout 120s;
}
