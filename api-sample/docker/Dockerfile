FROM eclipse-temurin:21.0.13_9-jre@sha256:ca73b4d3961703d6d7830a4361f49ef0478f8f28b39defc07bb72f4cc7f834f6
RUN mkdir -p /sync && chown 10001:10001 /sync
COPY --chown=10001:10001 app/build/install/products-api/ /opt/api/
USER 10001:10001
ENTRYPOINT ["/opt/api/bin/products-api"]
