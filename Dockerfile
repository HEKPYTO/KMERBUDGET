FROM debian:bookworm-slim AS build
ARG TARGETARCH
ARG ZIG_VERSION=0.17.1
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
        amd64) zig_arch=x86_64 ;; \
        arm64) zig_arch=aarch64 ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt \
    && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig
WORKDIR /src
COPY . .
ARG COMMIT=unknown
RUN /opt/zig/zig build -Doptimize=ReleaseFast -Dcommit="${COMMIT}"

FROM scratch
COPY --from=build /src/zig-out/bin/kmerbudget /kmerbudget
EXPOSE 8080
ENTRYPOINT ["/kmerbudget", "serve", "--host", "0.0.0.0", "--port", "8080"]
