# syntax=docker/dockerfile:1
FROM eclipse-temurin:21.0.13_9-jdk-jammy@sha256:a8b6e4da662e2ff710459e76be515a14746045c7a7493531d0901ca10a231501 AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/root/.gradle ./gradlew --no-daemon --max-workers=2 :batch-examples:bootJar

FROM eclipse-temurin:21.0.13_9-jre-jammy@sha256:f1ad2fff1437cbcf7be96408f264ad5d2128fad9cf262f88f1827a84e60d246e
WORKDIR /opt/batch
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /opt/batch/certs/rds-global-bundle.pem
RUN chmod 0444 /opt/batch/certs/rds-global-bundle.pem
COPY --from=build --chown=10001:10001 /src/batch-examples/build/libs/batch-examples.jar /opt/batch/batch-examples.jar
ENV JAVA_TOOL_OPTIONS="-Xmx512m -XX:+ExitOnOutOfMemoryError"
USER 10001:10001
ENTRYPOINT ["java", "-jar", "/opt/batch/batch-examples.jar"]
