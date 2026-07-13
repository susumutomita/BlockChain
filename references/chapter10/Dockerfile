FROM alpine:latest

RUN apk add --no-cache curl tar xz

ARG ZIG_VERSION=0.14.0
ARG TARGETARCH
ENV ZIG_VERSION=${ZIG_VERSION}

RUN case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    ZIG_DIST="zig-linux-${ZIG_ARCH}-${ZIG_VERSION}" && \
    curl -fLO "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIST}.tar.xz" && \
    mkdir -p /opt/zig && \
    tar -xf "${ZIG_DIST}.tar.xz" -C /opt/zig --strip-components=1 && \
    rm "${ZIG_DIST}.tar.xz"
ENV PATH="/opt/zig:${PATH}"

RUN addgroup -S appgroup && \
  adduser -S appuser -G appgroup && \
  mkdir -p /app && chown -R appuser:appgroup /app

WORKDIR /app
COPY --chown=appuser:appgroup . .
USER appuser
CMD ["zig", "build"]
