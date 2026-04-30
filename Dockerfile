ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY migrate.sh /opt/mongo-2-pg/migrate.sh
COPY scripts/   /opt/mongo-2-pg/scripts/
COPY test/       /opt/mongo-2-pg/test/
RUN chmod +x /opt/mongo-2-pg/migrate.sh /opt/mongo-2-pg/scripts/*.sh /opt/mongo-2-pg/test/*.sh

ENV PATH="/opt/mongo-2-pg:${PATH}"

WORKDIR /opt/mongo-2-pg

ENTRYPOINT ["/bin/bash"]
