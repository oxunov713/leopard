# syntax=docker/dockerfile:1

# ---- build ----
FROM golang:1.24-bookworm AS build
WORKDIR /src

# Dependencies first so they are cached independently of source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Fully static binary: no cgo, no libc, reproducible paths, stripped symbols.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/leopard-api ./cmd/leopard-api

# ---- run ----
# distroless/static has no shell and no package manager; :nonroot runs as uid 65532.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/leopard-api /leopard-api
USER nonroot:nonroot
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/leopard-api"]
