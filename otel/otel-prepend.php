<?php
/**
 * auto_prepend chain bootstrap — IMAGE-OWNED, lives at /opt/otel (OUTSIDE the
 * WordPress webroot, so the cluster PVC mounted over the docroot cannot mask it).
 *
 * WHY THIS FILE EXISTS
 *   The OpenTelemetry SDK auto-instrumentation must be loaded via PHP's single
 *   `auto_prepend_file` slot so its hooks register before WordPress/plugins run.
 *   Wordfence's WAF ALSO wants that slot: it writes `auto_prepend_file=.../wordfence-waf.php`
 *   into a webroot `.user.ini` (PHP_INI_PERDIR), which overrides the image's
 *   conf.d setting. There is only ONE slot, so we cannot let both win by config.
 *
 *   The cluster points the slot at THIS file via `php_admin_value[auto_prepend_file]`
 *   in the php-fpm pool (manifests/wordpress/config/php/www.conf). `php_admin_value`
 *   is PHP_INI_SYSTEM — a `.user.ini` CANNOT override it — so this bootstrap wins
 *   deterministically. We then load BOTH consumers ourselves, in order:
 *     1. OpenTelemetry SDK + auto-instrumentation (registers hooks; dormant
 *        unless OTEL_PHP_AUTOLOAD_ENABLED=true in env).
 *     2. Wordfence's WAF prepend — we took its slot, so we must invoke it, or the
 *        firewall silently stops running.
 *
 * NEVER FATAL: tracing must never take the site down. The site has ZERO runtime
 * dependency on this loading successfully.
 *
 * NOTE: this only runs for php-fpm (web) requests — the pool sets the slot, not
 * the CLI. wp-cli/cron is unaffected (and was never WAF-prepended either).
 */

// 0) Continuous profiler FIRST — start the excimer sampler before any app code
//    so it captures the full request (incl. the plugin/theme/core PHP that runs
//    before WordPress's main query). Self-gated by PYROSCOPE_ENABLED; inert and
//    dependency-free otherwise. Never fatal.
if ( is_readable( '/opt/otel/profiler.php' ) ) {
	require_once '/opt/otel/profiler.php';
}

// 1) OpenTelemetry SDK + auto-instrumentation. Wrapped so a runtime exception in
//    SDK init can never bubble into the request. (A compile-time fatal such as a
//    class redeclaration is NOT catchable here — that class of failure is
//    prevented upstream by keeping /opt/otel's deps free of libraries the app
//    bundles: see otel/composer.json, which uses php-http/curl-client, not the
//    guzzle that CiviCRM/plugins ship their own copy of.)
if ( PHP_SAPI !== 'cli' ) {
	$otel_autoload = '/opt/otel/vendor/autoload.php';
	if ( is_readable( $otel_autoload ) ) {
		try {
			require_once $otel_autoload;
		} catch ( \Throwable $e ) {
			// Swallow — never break the request for a tracing failure.
		}
	}
}

// 2) Chain Wordfence's WAF. Its loader lives in the webroot (PVC). We invoke it
//    because we displaced its `.user.ini` auto_prepend. Guarded so a missing/
//    deactivated Wordfence simply means no WAF prepend, not a fatal.
$wordfence_waf = '/usr/local/www/wordpress/wordfence-waf.php';
if ( is_readable( $wordfence_waf ) ) {
	require_once $wordfence_waf;
}
