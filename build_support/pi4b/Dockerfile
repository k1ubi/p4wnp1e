# Reproducible cross-build container for the Pi4B port.
#
# Compare to build_support/Dockerfile (the original): that one has to clone a
# Kali rolling image, install a pinned old Go release for GopherJS
# compatibility, clone three separate mame82 Go-source repos by hand into
# GOPATH because GopherJS has no module support, and then build. None of that
# is needed here:
#
#   - The backend (P4wnP1_service/P4wnP1_cli) has no cgo dependency and no
#     arch-specific code left post-port, so a stock upstream Go image
#     cross-compiles it for arm64 in one step.
#   - The WebUI (build/webapp.js) is prebuilt and architecture-independent
#     JavaScript - it ships as-is, no GopherJS toolchain required at all for a
#     hardware port.
#
# Build:  docker build -f build_support/pi4b/Dockerfile -t p4wnp1-pi4b-build .
# Run:    docker run --rm -v "$PWD/build:/out" p4wnp1-pi4b-build

FROM golang:1.23-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .

ENV GOOS=linux
ENV GOARCH=arm64
ENV CGO_ENABLED=0

RUN go build -o /out/P4wnP1_service ./cmd/P4wnP1_service/ \
 && go build -o /out/P4wnP1_cli ./cmd/P4wnP1_cli/

FROM scratch AS export
COPY --from=build /out/P4wnP1_service /out/P4wnP1_cli /
