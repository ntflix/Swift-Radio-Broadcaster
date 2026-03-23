# syntax=docker/dockerfile:1

FROM swift:6.2-noble AS build
# ================================
# Build image
# ================================

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package resolve \
    $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire repo into container
COPY . .

RUN mkdir /staging

# Build the application, with optimizations, with static linking, and using jemalloc
# N.B.: The static version of jemalloc is incompatible with the static Swift runtime.
RUN --mount=type=cache,id=radio-build-cache,target=/build/.build \
    swift build -c release \
    --product Radio \
    --static-swift-stdlib \
    -Xlinker -ljemalloc && \
    # Copy main executable to staging area
    cp "$(swift build -c release --show-bin-path)/Radio" /staging && \
    # Copy resources bundled by SPM to staging area
    find -L "$(swift build -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


# Switch to the staging area
WORKDIR /staging

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy any resources from the public directory and views directory if the directories exist
# Ensure that by default, neither the directory nor any of its contents are writable.
RUN [ -d /build/Public ] && { mv /build/Public ./Public && chmod -R a-w ./Public; } || true
RUN [ -d /build/Resources ] && { mv /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    libjemalloc2 \
    ca-certificates \
    tzdata \
    ffmpeg \
    libatomic1 \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /staging/Radio /usr/local/bin/Radio

RUN useradd --system --create-home --home-dir /app radio \
    && chown -R radio:radio /app

USER radio

EXPOSE 17298

ENTRYPOINT ["Radio"]
