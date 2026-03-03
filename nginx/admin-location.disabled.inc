# Default policy: /admin is closed to reduce attack surface.
location = /admin {
    return 404;
}

location ^~ /admin/ {
    return 404;
}
