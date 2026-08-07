#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f deploy.yaml
kubectl -n perf-fakeserver rollout status deploy/fake-webserver --timeout=5m
