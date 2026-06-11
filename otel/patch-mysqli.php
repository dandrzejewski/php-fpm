<?php
/**
 * Build-time patch for open-telemetry/opentelemetry-auto-mysqli.
 *
 * BUG (auto-mysqli 0.4.0): the mysqli_connect post-hook calls
 *   MySqliTracker::storeMySqliAttributes(..., $port, ...)
 * passing `$params[$paramsOffset + 4] ?? null` as the port. WordPress/wpdb calls
 * mysqli connect with the port argument as `false` (not null), so `?? null`
 * does NOT normalize it, and storeMySqliAttributes' `?int $port` parameter
 * rejects `false` with a TypeError. The extension surfaces the thrown hook as a
 * PHP Warning on EVERY request ("OpenTelemetry: post hook threw exception ...
 * $port must be of type ?int, false given"), flooding php-fpm stderr -> Loki.
 *
 * FIX: coerce the port argument to int-or-null at the call site. A real int port
 * is preserved; anything else (false, '', non-numeric) becomes null — a missing
 * port attribute, not a fatal. Query spans are unaffected (separate hook).
 *
 * Fixed-string replace with a strict count assertion: if a future auto-mysqli
 * version changes this line, the replacement count != 1 and the BUILD FAILS
 * loudly, prompting a re-check instead of silently shipping an unpatched (or
 * double-patched) file. Revisit/remove once upstream releases a fix.
 */

$file = '/opt/otel/vendor/open-telemetry/opentelemetry-auto-mysqli/src/MySqliInstrumentation.php';

if (!is_file($file)) {
    fwrite(STDERR, "patch-mysqli: target not found: $file\n");
    exit(1);
}

$src = file_get_contents($file);

$old = '$params[$paramsOffset + 4] ?? null, null);';
$new = '(is_int($params[$paramsOffset + 4] ?? null) ? $params[$paramsOffset + 4] : null), null);';

$patched = str_replace($old, $new, $src, $count);

if ($count !== 1) {
    fwrite(STDERR, "patch-mysqli: expected exactly 1 replacement, made $count — auto-mysqli changed, re-check the port fix.\n");
    exit(1);
}

file_put_contents($file, $patched);
echo "patch-mysqli: ok (coerced mysqli_connect port arg to ?int)\n";
