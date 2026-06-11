<?php
/**
 * Per-request continuous profiler — IMAGE-OWNED, /opt/otel (outside webroot).
 * Required FIRST from otel-prepend.php so the excimer sampler starts before any
 * application code (it must capture the ~1.7s of plugin/theme/core PHP that runs
 * before WordPress's main query — the part the OTel trace waterfall leaves blank).
 *
 * Mechanism: ext-excimer (in the image) wall-clock samples the FULL call stack
 * every N ms — i.e. it instruments EVERYTHING, every function, with no
 * hand-picked spans. On shutdown the folded stacks are POSTed to Grafana
 * Pyroscope's /ingest, labelled service_name + trace_id so a Tempo span opens
 * its exact flamegraph (Grafana "trace to profiles").
 *
 * We push with a dependency-free fire-and-forget socket write rather than the
 * Excimetry/Pyroscope SDKs ON PURPOSE: those pull guzzlehttp/guzzle, which
 * redeclares against CiviCRM/plugin guzzle and 502s php-fpm. excimer does the
 * real, complete profiling; this only ships its output. Never fatal — a
 * profiling/transport failure must never affect the page.
 *
 * Gated by PYROSCOPE_ENABLED=true (env) so the image ships inert: with the flag
 * unset this file no-ops, exactly like the SDK is inert without
 * OTEL_PHP_AUTOLOAD_ENABLED.
 */

if ( PHP_SAPI === 'cli' ) {
	return;
}
if ( getenv( 'PYROSCOPE_ENABLED' ) !== 'true' ) {
	return;
}
if ( ! extension_loaded( 'excimer' ) ) {
	return;
}

$__pyro_period = (float) ( getenv( 'PYROSCOPE_SAMPLE_PERIOD' ) ?: '0.01' ); // 10ms -> 100Hz
$GLOBALS['__pyro_start'] = microtime( true );
$GLOBALS['__pyro']       = new ExcimerProfiler();
$GLOBALS['__pyro']->setPeriod( $__pyro_period );
$GLOBALS['__pyro']->setEventType( EXCIMER_REAL ); // wall-clock (covers I/O waits + CPU)
$GLOBALS['__pyro']->start();

register_shutdown_function(
	static function () use ( $__pyro_period ) {
		$prof = $GLOBALS['__pyro'] ?? null;
		if ( ! $prof ) {
			return;
		}
		try {
			$prof->stop();
			$folded = $prof->getLog()->formatCollapsed();
			if ( '' === $folded ) {
				return;
			}

			$from  = (int) ( $GLOBALS['__pyro_start'] ?? microtime( true ) );
			$until = (int) microtime( true );
			if ( $until <= $from ) {
				$until = $from + 1;
			}

			// trace_id for trace<->profile correlation: try the live OTel span,
			// then fall back to the value the logbridge mu-plugin captured.
			$tid = '';
			if ( class_exists( '\OpenTelemetry\API\Trace\Span' ) ) {
				try {
					$ctx = \OpenTelemetry\API\Trace\Span::getCurrent()->getContext();
					if ( $ctx->isValid() ) {
						$tid = $ctx->getTraceId();
					}
				} catch ( \Throwable $e ) {
					$tid = '';
				}
			}
			if ( '' === $tid && ! empty( $GLOBALS['__otel_tid'] ) ) {
				$tid = (string) $GLOBALS['__otel_tid'];
			}

			$svc    = getenv( 'OTEL_SERVICE_NAME' ) ?: 'wordpress';
			$labels = 'service_name=' . $svc;
			if ( '' !== $tid ) {
				$labels .= ',trace_id=' . $tid;
			}
			$name = rawurlencode( $svc ) . '{' . $labels . '}';
			$rate = (int) round( 1.0 / ( $__pyro_period > 0 ? $__pyro_period : 0.01 ) );

			$base = getenv( 'PYROSCOPE_SERVER_URL' ) ?: 'http://pyroscope.pyroscope.svc:4040';
			$u    = parse_url( $base );
			$host = $u['host'] ?? 'pyroscope.pyroscope.svc';
			$port = (int) ( $u['port'] ?? 4040 );
			$path = '/ingest?name=' . $name
				. '&from=' . $from . '&until=' . $until
				. '&sampleRate=' . $rate
				. '&format=folded&spyName=phpspy&units=samples&aggregationType=sum';

			// Fire-and-forget POST: short connect timeout, loop the write for
			// large bodies, never read the response (no added page latency).
			$fp = @fsockopen( $host, $port, $errno, $errstr, 1 );
			if ( ! $fp ) {
				return;
			}
			$req = "POST {$path} HTTP/1.1\r\n"
				. "Host: {$host}\r\n"
				. "Content-Type: text/plain\r\n"
				. 'Content-Length: ' . strlen( $folded ) . "\r\n"
				. "Connection: close\r\n\r\n"
				. $folded;
			@stream_set_timeout( $fp, 2 );
			$len = strlen( $req );
			$off = 0;
			while ( $off < $len ) {
				$n = @fwrite( $fp, substr( $req, $off ) );
				if ( false === $n || 0 === $n ) {
					break;
				}
				$off += $n;
			}
			@fclose( $fp );
		} catch ( \Throwable $e ) {
			// Never let profiling affect the request.
		}
	}
);
