FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    git \
    curl \
    jq \
    openssh-client \
    python3 \
    ca-certificates

# Global git config for mirror operations
RUN git config --global credential.helper store && \
    git config --global http.sslVerify false && \
    git config --global user.email "sync@gitlab-tfs-mirror" && \
    git config --global user.name "TFS-GitLab Sync" && \
    git config --global http.postBuffer 524288000

WORKDIR /app
COPY sync.sh .
RUN chmod +x sync.sh

VOLUME ["/repos"]
CMD ["/app/sync.sh"]
