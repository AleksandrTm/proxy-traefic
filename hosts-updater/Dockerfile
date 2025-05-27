FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      jq mkcert libnss3 openssl ca-certificates \
      docker.io && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY watcher.sh /app/watcher.sh
RUN chmod +x /app/watcher.sh

ENTRYPOINT ["/app/watcher.sh"]
