FROM golang:1.23 as builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o pod-manager ./cmd/webhook

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/pod-manager .
# 证书将在运行时动态生成
RUN mkdir -p /etc/webhook/certs
CMD ["./pod-manager"]