# PHP 8.5-FPM image for the WordPress/CRM stack, served over FastCGI :9000
# behind nginx and run rootless on the Talos cluster.
#
# Base pinned by digest for reproducibility (tag 26.04 moves). Re-resolve with:
#   docker buildx imagetools inspect ubuntu:26.04
FROM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944

LABEL org.opencontainers.image.source="https://github.com/dandrzejewski/php-fpm" \
      org.opencontainers.image.description="PHP 8.5-FPM + WP-CLI for the WordPress/CRM stack"

# wp-cli release to install (verified against its published sha512 below).
ARG WPCLI_VERSION=2.12.0

# cv (CiviCRM CLI) release to install (verified against its published SHA256 below).
ARG CV_VERSION=0.3.72

# OpenTelemetry PHP extensions, built from PECL (Ubuntu does not package them).
# Pinned to current stable; protobuf gives fast OTLP serialization. We export
# OTLP over http/protobuf, so grpc is intentionally NOT installed.
ARG OTEL_EXT_VERSION=1.4.2
ARG PROTOBUF_EXT_VERSION=5.36.2
# sha256 of https://pecl.php.net/get/<ext>-<version>.tgz for each extension.
# Both are fetched as tarballs and verified, not resolved by pecl name: pecl's
# REST lookup for opentelemetry is broken ("does not have REST xml available",
# every version), and pinning both keeps their supply-chain guarantee equal.
# PECL publishes no checksum; recompute on a version bump with:
#   curl -fsSL https://pecl.php.net/get/<ext>-<ver>.tgz | sha256sum
ARG OTEL_EXT_SHA256=a355329259f373c5c7327e66310481726cfabac50cb5483eba000bec791d5017
ARG PROTOBUF_EXT_SHA256=f0a17c67de29df0fb0e5215a381df9b155125e1ace6252dd617bf16b4194dd5b

# Minimum acceptable Ubuntu php8.5 package. 8.5.4-0ubuntu1.5 (USN-8948-1) fixes
# CVE-2026-109618 + CVE-2026-109619 (PHP2Shell unauthenticated RCE). The build
# fails below this floor, so a stale mirror can never ship a vulnerable image.
# Raise it whenever a later USN fixes something we must not regress on.
ARG PHP_MIN_PKG_VERSION=8.5.4-0ubuntu1.5

# Single layer: install runtime deps, fetch+verify wp-cli, then strip build-only
# tooling and apt lists. DEBIAN_FRONTEND avoids interactive prompts;
# --no-install-recommends keeps the image lean.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    # Apply security/bugfix updates on top of the pinned base. The FROM digest
    # pins the floor; this layers current patches at build time (so two builds
    # apart can differ — intended, it keeps CVEs patched).
    apt-get -y dist-upgrade; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
        php8.5-fpm php8.5-cli \
        php-apcu php-bcmath php-bz2 php-common php-composer-ca-bundle \
        php-composer-metadata-minifier php-composer-pcre php-composer-semver \
        php-composer-spdx-licenses php-curl php-excimer php-gd \
        php-google-recaptcha php-imagick php-intl php-json php-json-schema \
        php-mariadb-mysql-kbs php-mbstring php-memcached php-mysql \
        php-nikic-fast-route php-pear php-phpmyadmin-motranslator \
        php-phpmyadmin-shapefile php-phpmyadmin-sql-parser php-phpseclib \
        php-predis php-psr-cache php-psr-container php-psr-log \
        php-react-promise php-redis php-soap php-symfony-cache \
        php-symfony-cache-contracts php-symfony-config php-symfony-console \
        php-symfony-dependency-injection php-symfony-deprecation-contracts \
        php-symfony-expression-language php-symfony-filesystem \
        php-symfony-finder php-symfony-polyfill-php80 php-symfony-polyfill-php81 \
        php-symfony-process php-symfony-service-contracts php-symfony-string \
        php-symfony-var-exporter php-tcpdf php-twig php-twig-i18n-extension \
        php-xml php-xmlrpc php-zip php-gmp php-dom php-fileinfo php-simplexml \
        php-xmlreader php-xmlwriter php-mysqli php-exif php-ldap; \
    \
    # Security floor: refuse to build if apt resolved a php8.5 older than the
    # fixed package (see PHP_MIN_PKG_VERSION above).
    for pkg in php8.5-fpm php8.5-cli; do \
        v="$(dpkg-query -W -f='${Version}' "$pkg")"; \
        dpkg --compare-versions "$v" ge "${PHP_MIN_PKG_VERSION}" \
            || { echo "ERROR: $pkg $v < ${PHP_MIN_PKG_VERSION}" >&2; exit 1; }; \
    done; \
    \
    # wp-cli: download release phar + verify sha512 before trusting it.
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar"; \
    curl -fsSL -o /tmp/wp.sha512 \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar.sha512"; \
    echo "$(cat /tmp/wp.sha512)  /usr/local/bin/wp" | sha512sum -c -; \
    chmod 0755 /usr/local/bin/wp; \
    rm -f /tmp/wp.sha512; \
    \
    # cv: CiviCRM CLI. Pin to a tagged GitHub release + verify its published
    # SHA256 before trusting it — same pattern as wp-cli above. (The canonical
    # download.civicrm.org/cv/cv.phar is a rolling build with no checksum, so we
    # pull the versioned release asset instead. -L follows GitHub's 302.)
    curl -fsSL -o /usr/local/bin/cv \
        "https://github.com/civicrm/cv/releases/download/v${CV_VERSION}/cv-${CV_VERSION}.phar"; \
    curl -fsSL -o /tmp/cv.SHA256SUMS \
        "https://github.com/civicrm/cv/releases/download/v${CV_VERSION}/cv-${CV_VERSION}.SHA256SUMS"; \
    echo "$(awk '{print $1}' /tmp/cv.SHA256SUMS)  /usr/local/bin/cv" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/cv; \
    rm -f /tmp/cv.SHA256SUMS; \
    \
    # Strip build-only tooling + apt metadata to shrink the image.
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

# Pool: listen on TCP :9000 (Ubuntu default is a unix socket, which nginx here
# does not use). Logs to stderr so they surface in `kubectl logs`. The pool
# user/group directives are intentionally left default — php-fpm ignores them
# when the master is not root (see USER below).
RUN set -eux; \
    sed -ri 's#^;?listen = .*#listen = 9000#' /etc/php/8.5/fpm/pool.d/www.conf; \
    sed -ri 's#^;?catch_workers_output = .*#catch_workers_output = yes#' /etc/php/8.5/fpm/pool.d/www.conf; \
    sed -ri 's#^;?error_log = .*#error_log = /proc/self/fd/2#' /etc/php/8.5/fpm/php-fpm.conf; \
    sed -ri 's#^;?daemonize = .*#daemonize = no#' /etc/php/8.5/fpm/php-fpm.conf

# Defense-in-depth for CVE-2026-109619 (PHP2Shell): both settings feed the
# stale-state RCE path and nothing in WordPress/CiviCRM needs them. Session
# upload progress is on by default; fatal-error backtraces are on by default in
# PHP 8.5. Lives in conf.d because the cluster mounts its own php.ini over ours
# (conf.d is not mounted, and is scanned after php.ini, so it beats php.ini).
# This is a DEFAULT only: a webroot .user.ini can override upload_progress
# (PHP_INI_PERDIR) and ini_set() can override fatal_error_backtraces. The
# AUTHORITATIVE setting is php_admin_flag in the cluster's php-fpm pool — same
# split as auto_prepend_file below. The grep fails the build if FPM doesn't
# actually pick these up (path typo, SAPI dir change).
RUN set -eux; \
    printf '; PHP2Shell (CVE-2026-109619) hardening; see Containerfile.\nsession.upload_progress.enabled = 0\nfatal_error_backtraces = 0\n' \
        > /etc/php/8.5/fpm/conf.d/zz-hardening.ini; \
    test "$(php-fpm8.5 -i | grep -cE '^(session\.upload_progress\.enabled|fatal_error_backtraces) => Off => Off$')" -eq 2

# --- OpenTelemetry distributed tracing --------------------------------------
# EVERYTHING here lives OUTSIDE the WordPress webroot. At runtime the cluster
# mounts a PersistentVolume over /usr/local/www/wordpress (incl. wp-content),
# so anything baked into the docroot is masked and vanishes. The OTel SDK is
# therefore installed to /opt/otel, the extensions live in the system PHP tree,
# and activation rides in a conf.d drop-in. None of that is under the docroot.
#
# composer.json for the SDK bootstrap. Copied to a NON-webroot path so the PVC
# mount cannot mask the vendor/ tree (a composer install under the docroot would
# disappear at runtime).
COPY otel/composer.json /opt/otel/composer.json

# auto_prepend chain bootstrap (loads the OTel SDK, then chains Wordfence's WAF).
# The cluster points php_admin_value[auto_prepend_file] at this so it wins over
# Wordfence's webroot .user.ini. Also under /opt so the PVC cannot mask it.
COPY otel/otel-prepend.php /opt/otel/otel-prepend.php

# Per-request continuous profiler (excimer -> Pyroscope). Required first by
# otel-prepend.php. Inert unless PYROSCOPE_ENABLED=true. Dependency-free push
# (no guzzle) — see otel/profiler.php.
COPY otel/profiler.php /opt/otel/profiler.php

# Build-time patch for an auto-mysqli 0.4.0 type bug (mysqli_connect port arg
# `false` vs ?int -> a PHP Warning per request). Applied after composer install
# below. See otel/patch-mysqli.php for the rationale + the build-fails-loudly
# assertion that guards against silent drift on an upstream version bump.
COPY otel/patch-mysqli.php /opt/otel/patch-mysqli.php

# One ephemeral layer: pull build toolchain (php-dev + compiler), build the two
# PECL extensions, enable them the Ubuntu-native way (mods-available + phpenmod
# so the symlinks land in conf.d, which survives the runtime mounts), composer
# install the SDK into /opt/otel, write the activation drop-in, then purge the
# build toolchain so it never reaches the final image. composer is pulled too;
# it is pure-PHP and tiny, so we keep it for on-cluster debugging of /opt/otel.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    # Build-only: phpize/php-config (php8.5-dev), a C/C++ toolchain
    # (build-essential — protobuf's ext is C++), autoconf + pkg-config for the
    # PECL build. composer drives the /opt/otel install. All but composer are
    # purged at the end of this same layer.
    apt-get install -y --no-install-recommends \
        php8.5-dev build-essential autoconf pkg-config composer curl; \
    \
    # Build + install the extensions. pecl drops the .so into the 8.5 extension
    # dir but does NOT wire Debian/Ubuntu's conf.d — we do that next. pecl
    # SKIPS a package it can't resolve yet still exits 0, so the extension_loaded
    # check below is what actually catches a missing ext. Both come from
    # sha256-verified local tarballs (see *_EXT_SHA256 above).
    curl -fsSL -o /tmp/opentelemetry.tgz \
        "https://pecl.php.net/get/opentelemetry-${OTEL_EXT_VERSION}.tgz"; \
    curl -fsSL -o /tmp/protobuf.tgz \
        "https://pecl.php.net/get/protobuf-${PROTOBUF_EXT_VERSION}.tgz"; \
    echo "${OTEL_EXT_SHA256}  /tmp/opentelemetry.tgz" | sha256sum -c -; \
    echo "${PROTOBUF_EXT_SHA256}  /tmp/protobuf.tgz" | sha256sum -c -; \
    pecl install /tmp/opentelemetry.tgz /tmp/protobuf.tgz; \
    rm -f /tmp/opentelemetry.tgz /tmp/protobuf.tgz; \
    \
    # Enable via mods-available + phpenmod (the Ubuntu-native path). phpenmod
    # symlinks these into BOTH cli and fpm conf.d. conf.d is NOT mounted over at
    # runtime, so the extensions stay loaded under the cluster's php.ini.
    # protobuf at priority 15 so it initialises before opentelemetry (20).
    printf '; priority=15\nextension=protobuf.so\n' \
        > /etc/php/8.5/mods-available/protobuf.ini; \
    printf '; priority=20\nextension=opentelemetry.so\n' \
        > /etc/php/8.5/mods-available/opentelemetry.ini; \
    phpenmod -v 8.5 protobuf opentelemetry; \
    # Fail loudly if either extension did not build/load (pecl can exit 0 on a
    # package it skipped; see above).
    php -r 'foreach (["protobuf","opentelemetry"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "ERROR: ext $e not loaded\n"); exit(1); } }'; \
    \
    # Resolve + install the SDK into /opt/otel. --no-dev keeps it lean; the lock
    # generated here pins exact versions inside the image. Platform reqs
    # (ext-opentelemetry) are satisfied because we enabled the ext above, so the
    # cli running composer already loads it.
    composer update --no-dev --no-interaction --no-progress --prefer-dist \
        --optimize-autoloader --working-dir=/opt/otel; \
    \
    # Patch the auto-mysqli port-type bug (see otel/patch-mysqli.php). Runs after
    # install so it edits the resolved vendor tree; fails the build if the target
    # line is gone (upstream changed) instead of silently shipping unpatched.
    php /opt/otel/patch-mysqli.php; \
    \
    # Activation drop-in the IMAGE owns. At runtime the cluster mounts its own
    # php.ini/php-fpm.conf/pool.d over ours via subPath, but conf.d is not
    # mounted — so this survives. This is a DEFAULT only: conf.d is overridden by
    # a webroot .user.ini (PHP_INI_PERDIR beats conf.d), which is exactly how
    # Wordfence steals the slot. The AUTHORITATIVE setting is the cluster's
    # php_admin_value[auto_prepend_file] in the php-fpm pool (PHP_INI_SYSTEM —
    # .user.ini cannot override it), also pointed at otel-prepend.php. We target
    # the CHAIN bootstrap (not vendor/autoload.php directly) so Wordfence's WAF
    # still loads after the SDK — see otel/otel-prepend.php.
    printf '; Default activation: load the OTel SDK + chain Wordfence on each web\n; request. Authoritative slot is php_admin_value in the pool (see www.conf).\n; /opt is outside the webroot, so the PVC mount cannot hide it.\nauto_prepend_file=/opt/otel/otel-prepend.php\n' \
        > /etc/php/8.5/fpm/conf.d/zz-otel.ini; \
    \
    # Drop the build toolchain (NOT composer) and caches from this layer.
    apt-get purge -y --auto-remove php8.5-dev build-essential autoconf pkg-config curl; \
    rm -rf /var/lib/apt/lists/* /tmp/pear /root/.composer /root/.cache

# Run unprivileged (uid 33 ships in the base). :9000 > 1024, so non-root binds it.
USER www-data

EXPOSE 9000

# Liveness: confirm the FastCGI listener accepts connections. bash /dev/tcp
# avoids re-adding curl/nc just for the probe.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000' || exit 1

# -F = foreground (no pid file needed; /var/run isn't writable by www-data).
CMD ["/usr/sbin/php-fpm8.5", "-F", "-y", "/etc/php/8.5/fpm/php-fpm.conf"]
