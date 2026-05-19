/*
 * Scripted API monitor — instant-api healthz scripted (build-SHA freshness)
 *
 * Goes beyond a simple ping: asserts the /healthz JSON body is well-formed,
 * reports ok:true, carries a non-placeholder commit_id, and was built
 * recently. This catches a class of silent failures a status-code ping
 * misses entirely:
 *   - the api is up but serving a stale image (commit_id never changes,
 *     build_time months old) — a deploy that never actually rolled out;
 *   - commit_id == "dev" — an un-instrumented build shipped to prod
 *     (the ldflags GIT_SHA stamp was skipped);
 *   - migration_status != "ok" — the binary booted but the schema is behind.
 *
 * A FAILED assertion here surfaces in NRQL as
 *   SyntheticCheck WHERE monitorName = 'instant-api healthz scripted (build-SHA freshness)' AND result = 'FAILED'
 * and feeds the api-healthz-down alert.
 *
 * MAX_BUILD_AGE_DAYS is a soft freshness bound, not a deploy cadence
 * requirement: a healthy low-change week is fine. Re-tune if the team
 * deliberately freezes deploys for longer than this window.
 */

var assert = require('assert');

var HEALTHZ_URL = 'https://api.instanode.dev/healthz';
var MAX_BUILD_AGE_DAYS = 30;

$http.get(
  { url: HEALTHZ_URL, timeout: 10000 },
  function callback(err, response, body) {
    assert.ok(!err, 'request to /healthz errored: ' + err);
    assert.equal(response.statusCode, 200,
      '/healthz returned ' + response.statusCode + ' (expected 200)');

    var payload;
    try {
      payload = JSON.parse(body);
    } catch (e) {
      assert.fail('/healthz body is not valid JSON: ' + body);
    }

    assert.equal(payload.ok, true,
      '/healthz reported ok=' + payload.ok + ' (expected true)');

    assert.ok(
      typeof payload.commit_id === 'string' && payload.commit_id.length > 0,
      '/healthz has no commit_id — build was not SHA-stamped');
    assert.notEqual(payload.commit_id, 'dev',
      '/healthz commit_id is "dev" — an un-instrumented build is in prod');
    assert.notEqual(payload.commit_id, 'unknown',
      '/healthz commit_id is "unknown" — build metadata missing');

    if (payload.migration_status) {
      assert.equal(payload.migration_status, 'ok',
        '/healthz migration_status=' + payload.migration_status +
        ' (expected ok) — schema is behind the running binary');
    }

    // Build-SHA freshness: the running image must not be stale.
    if (payload.build_time) {
      var built = Date.parse(payload.build_time);
      assert.ok(!isNaN(built),
        '/healthz build_time is unparseable: ' + payload.build_time);
      var ageDays = (Date.now() - built) / 86400000;
      assert.ok(ageDays <= MAX_BUILD_AGE_DAYS,
        '/healthz build is ' + ageDays.toFixed(1) + ' days old (max ' +
        MAX_BUILD_AGE_DAYS + ') — prod may be running a stale image; ' +
        'commit_id=' + payload.commit_id);
    }

    console.log('healthz ok — commit_id=' + payload.commit_id +
      ' build_time=' + payload.build_time +
      ' version=' + payload.version);
  }
);
