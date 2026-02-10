FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq curl bash postgresql-client imagemagick \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ruamel.yaml psycopg2-binary pyyaml

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
