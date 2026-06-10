# Handoff: wire OpenTelemetry tracing into the WordPress Deployment

You control the WordPress Deployment on `k8s-ash-prod`. The php-fpm **image** side
of OpenTelemetry is already built, verified, and pushed. Your job is the
**cluster** side: pin the new image, set the runtime `OTEL_*` env, ensure a
collector listens where the exporter points, and install the Sentry plugin into
the PVC. Do NOT try to configure tracing inside the image or the webroot — that
work is done and lives outside the docroot on purpose.

## 1. Pin the new image (digest-pinned)

Set the php-fpm container image to exactly this (multi-arch index digest):

```
ghcr.io/dandrzejewski/php-fpm:20260610-65ca382@sha256:0ad69a11e55ffc0e6152236fc93228ce86ff2d30cd444ddbf709328d4715f7f4
```

linux/amd64 manifest, if you pin per-arch instead:
`sha256:875d87d81255a02fee8a448b616c6187b94fed85c69bbba09f790c8db193fa05`

## What the image already provides (do NOT redo)

- PHP extensions `opentelemetry` (1.2.1) and `protobuf` (5.35.0) built and
  enabled. No `grpc` — export is OTLP over **http/protobuf**.
- OTel SDK + auto-instrumentation (WordPress, PDO, MySQLi) composer-installed to
  `/opt/otel` (OUTSIDE the webroot, so your PVC mount cannot mask it).
- Activation via conf.d drop-in `/etc/php/8.3/fpm/conf.d/zz-otel.ini` setting
  `auto_prepend_file=/opt/otel/vendor/autoload.php`. This survives your runtime
  mounts because the cluster mounts `php.ini`/`php-fpm.conf`/`pool.d/www.conf`
  via subPath but does NOT mount conf.d.

The instrumentation is dormant until `OTEL_PHP_AUTOLOAD_ENABLED=true` is set in
env (next step). With autoload off, the prepend loads harmlessly and does nothing.

## 2. Runtime OTEL_* env on the php-fpm container

Add these to the php-fpm container `env` (NOT baked into the image by design):

```yaml
- name: OTEL_PHP_AUTOLOAD_ENABLED
  value: "true"
- name: OTEL_SERVICE_NAME
  value: "wordpress"
- name: OTEL_TRACES_EXPORTER
  value: "otlp"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "http/protobuf"
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://127.0.0.1:4318"
# 10% head sampling; parentbased keeps child spans of a sampled trace consistent.
- name: OTEL_TRACES_SAMPLER
  value: "parentbased_traceidratio"
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"
# Traces only for now — silence metrics/logs exporters so the SDK does not try
# (and fail) to ship them. Drop these two if/when you wire metrics or logs.
- name: OTEL_METRICS_EXPORTER
  value: "none"
- name: OTEL_LOGS_EXPORTER
  value: "none"
# Optional but recommended: tag the environment on every span.
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment=production,service.namespace=wordpress"
```

Notes:
- The exporter appends `/v1/traces` to the endpoint itself — give it the base
  `http://127.0.0.1:4318`, not the full path.
- `127.0.0.1:4318` is loopback, so the collector MUST be in the SAME pod
  (sidecar). See next step.

## 3. Collector — OTLP http receiver on :4318 (the "collector-http flip")

The endpoint is pod-loopback, so add (or confirm) an OpenTelemetry Collector
**sidecar** in the WordPress pod with an OTLP receiver on `http` (port 4318):

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:4318
```

If you currently run a grpc-only receiver (:4317), this is the flip — enable the
`http` protocol on 4318. The php-fpm image deliberately has no grpc ext, so a
grpc-only collector receiver will get zero spans. Wire the collector's exporter
to your backend (Tempo/Jaeger/etc.) as you already do.

## 4. Sentry plugin — wp-cli install into the PVC (one-time)

Sentry is intentionally NOT in the image (it is wp-content = PVC). Install it
into the volume once, e.g. via a Job or `kubectl exec` into a running pod:

```bash
wp plugin install wp-sentry-integration --activate
```

Configure its DSN via env/wp-config as your Sentry setup requires (the image's
raw `sentry/sentry` SDK was deliberately not added — the plugin bundles its own).

## 5. Verify on-cluster after rollout

- `kubectl logs <pod> -c php-fpm` — php-fpm starts clean, no fatal/warning about
  missing OTel classes or PSR client.
- `kubectl logs <pod> -c <collector>` — spans arriving on the OTLP http receiver
  after a few WordPress requests.
- Confirm traces land in your tracing backend with service name `wordpress`, and
  that DB spans appear (PDO/MySQLi auto-instrumentation) under WordPress spans.
- Sanity-check sampling: roughly 10% of requests produce traces.
