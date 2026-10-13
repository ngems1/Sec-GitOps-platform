# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Week 3: Go 1.24 (the AWS SDK for Go v2 needs a recent Go), same as checkoutservice
FROM golang:1.26-alpine AS builder
RUN apk add --no-cache ca-certificates git curl
RUN apk add build-base

WORKDIR /src
# restore dependencies
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# Skaffold passes in debug-oriented compiler flags
ARG SKAFFOLD_GO_GCFLAGS
RUN go build -gcflags="${SKAFFOLD_GO_GCFLAGS}" -o /productcatalogservice .
# Week 3: unit tests run in every image build (cache, loader, fallbacks)
RUN go test -vet=off ./...
# Week 3: RDS certificate bundle, to verify the MySQL server's TLS certificate
RUN curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /rds-global-bundle.pem \
 && grep -q "BEGIN CERTIFICATE" /rds-global-bundle.pem \
 && chmod 0644 /rds-global-bundle.pem

# Week 3: runtime base image updated (the 2023 image had CRITICAL CVEs, blocked by the ECR scan gate)
FROM alpine:3.22
# The RDS folder is created with normal permissions (755) so the non-root user can read the bundle
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates \
 && mkdir -p -m 0755 /etc/ssl/rds
COPY --from=builder /rds-global-bundle.pem /etc/ssl/rds/global-bundle.pem
RUN su -s /bin/sh nobody -c "test -r /etc/ssl/rds/global-bundle.pem" \
 || { echo "RDS CA bundle not readable by non-root users"; exit 1; }

WORKDIR /src
COPY --from=builder /productcatalogservice ./server
COPY products.json .

# Definition of this variable is used by 'skaffold debug' to identify a golang binary.
# Default behavior - a failure prints a stack trace for the current goroutine.
# See https://golang.org/pkg/runtime/
ENV GOTRACEBACK=single

EXPOSE 3550
ENTRYPOINT ["/src/server"]
