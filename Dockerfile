FROM ubuntu:24.04

ARG MONGODB_VERSION=8.0
ARG TARGETOS=linux
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive

# Base system: shells, editors, network/debug tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    zsh \
    vim \
    nano \
    less \
    jq \
    yq \
    curl \
    wget \
    httpie \
    ca-certificates \
    gnupg \
    lsb-release \
    dnsutils \
    bind9-host \
    iputils-ping \
    traceroute \
    mtr-tiny \
    netcat-openbsd \
    nmap \
    tcpdump \
    iproute2 \
    iptables \
    net-tools \
    openssh-client \
    openssl \
    strace \
    htop \
    procps \
    psmisc \
    sysstat \
    tree \
    file \
    unzip \
    groff \
    git \
    make \
  && rm -rf /var/lib/apt/lists/*

# PostgreSQL client
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
  && rm -rf /var/lib/apt/lists/*

# MongoDB tools (mongosh, mongodump, mongorestore, etc.)
RUN curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc" | \
      gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server.gpg ] \
      https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/${MONGODB_VERSION} multiverse" | \
      tee /etc/apt/sources.list.d/mongodb-org.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      mongodb-mongosh \
      mongodb-database-tools \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/${TARGETOS}/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Copy migration scripts
COPY migrate.sh /opt/mongo-2-pg/migrate.sh
COPY scripts/   /opt/mongo-2-pg/scripts/
COPY test/       /opt/mongo-2-pg/test/
RUN chmod +x /opt/mongo-2-pg/migrate.sh /opt/mongo-2-pg/scripts/*.sh /opt/mongo-2-pg/test/*.sh

ENV PATH="/opt/mongo-2-pg:${PATH}"

WORKDIR /opt/mongo-2-pg

ENTRYPOINT ["/bin/bash"]
