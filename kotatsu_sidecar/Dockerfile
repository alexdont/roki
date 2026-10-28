# Build stage
FROM gradle:8.14-jdk21 AS build
WORKDIR /build
COPY settings.gradle.kts build.gradle.kts gradle.properties ./
COPY src ./src
RUN gradle shadowJar --no-daemon

# Runtime stage
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/build/libs/kotatsu-sidecar.jar .
ENV PORT=8420
# The sidecar has no auth. It binds loopback unless BIND says otherwise; roki's stack sets
# BIND=0.0.0.0 and publishes NO port, so only containers on its private network can reach it.
EXPOSE 8420
CMD ["java", "-Xmx512m", "-jar", "kotatsu-sidecar.jar"]
