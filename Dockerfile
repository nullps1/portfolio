# Static portfolio served by unprivileged nginx (listens on 8080, runs as UID 101).
FROM nginxinc/nginx-unprivileged:1.31-alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.source="https://github.com/nullps1/portfolio" \
      org.opencontainers.image.revision="${GIT_SHA}"

COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css script.js favicon.svg robots.txt /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
