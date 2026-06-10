# syntax=docker/dockerfile:1

# Global build args (must be declared before the first FROM to be usable in FROM lines).
ARG OPENBAO_VERSION=latest

###############################################################################
# Stage 1 — build the Ethereum signing plugin (kaleido-io/vault-plugin-secrets-ethsign)
#
# CGO is disabled on purpose: with CGO_ENABLED=0, go-ethereum's crypto package
# selects its pure-Go secp256k1 implementation, producing a fully static binary
# that runs unchanged on the (musl-based) OpenBao image.
###############################################################################
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git

ARG ETHSIGN_REPO=https://github.com/kaleido-io/vault-plugin-secrets-ethsign.git
# Pin to a specific commit for reproducible builds (override with a branch/tag/commit).
ARG ETHSIGN_REF=efdc481c29f9eb9a04c8c47e0636bdddc98b9163

WORKDIR /src
RUN git clone "${ETHSIGN_REPO}" . && git checkout "${ETHSIGN_REF}"

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ethsign .

###############################################################################
# Stage 2 — OpenBao image with the plugin baked into the plugin directory
###############################################################################
FROM openbao/openbao:${OPENBAO_VERSION}

USER root
RUN mkdir -p /openbao/plugins
COPY --from=builder /out/ethsign /openbao/plugins/ethsign
# plugin_directory must not be world-writable; binary must be executable.
RUN chmod 755 /openbao/plugins && chmod 755 /openbao/plugins/ethsign

USER openbao
