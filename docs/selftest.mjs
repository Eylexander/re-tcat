// Checks site/index.html's data layer against TCAT's live feeds: `node site/selftest.mjs`.
// It runs the page's own script, so the delay rules are tested where they are used (the app has test/feed_test.dart).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('index.html', import.meta.url), 'utf8');
const src = html.split('<script id="tcat">')[1].split('</script>')[0];
const TCAT = new Function(`${src}\nreturn TCAT;`)();

// --- the delay rules, without the network (same cases as test/feed_test.dart) ---
const at = (seq) => 1_000_000 + seq * 60; // scheduled epoch seconds of stop `seq`
const upd = (stops, canceled = false, delay = null) => {
  const seen = new Set(), placeholders = new Set();
  for (const s of stops) {
    if (s.time == null) continue;
    if (seen.has(s.time)) placeholders.add(s.time); else seen.add(s.time);
  }
  return { canceled, delay, stops, placeholders };
};
const stop = (seq, { time = null, delay = null, skipped = false } = {}) => ({ seq, time, delay, skipped });

assert.equal(TCAT.delayAt(upd([stop(2, { delay: 120 })]), 2, at), 120, 'its own delay');
assert.equal(TCAT.delayAt(upd([stop(2, { time: at(2) + 90 })]), 2, at), 90, 'its own time');
assert.equal(TCAT.delayAt(upd([stop(1, { delay: 60 }), stop(3, { delay: 300 })]), 2, at), 60, 'closest earlier stop');
assert.equal(TCAT.delayAt(upd([stop(2, { skipped: true })]), 2, at), TCAT.GONE, 'skipped');
assert.equal(TCAT.delayAt(upd([stop(1, {})], true), 1, at), TCAT.GONE, 'canceled');
assert.equal(TCAT.delayAt(upd([stop(4, { delay: 60 })]), 2, at), TCAT.GONE, 'already passed');
assert.equal(TCAT.delayAt(upd([stop(9, { delay: 30 })]), 9, at), 30, 'the only stop listed');
// A time shared by several stops is the feed's timestamp, not a prediction: its delay is used instead.
const shared = upd([stop(1, { time: 1_000_500, delay: 10 }), stop(2, { time: 1_000_500, delay: 20 })]);
assert.equal(TCAT.delayAt(shared, 2, at), 20, 'placeholder time ignored');

// --- the live feeds ---
const t0 = Date.now();
const gtfs = await TCAT.loadTimetable();
console.log(`horaires : ${gtfs.routes.size} lignes, ${gtfs.stations.size} arrêts, ${gtfs.trips.size} courses, `
  + `valables ${gtfs.validFrom}–${gtfs.validTo} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
assert.ok(gtfs.routes.size > 10 && gtfs.stations.size > 200 && gtfs.trips.size > 1000, 'timetable looks empty');
assert.match(gtfs.validTo, /^\d{8}$/);
assert.ok(!gtfs.expired, `the published timetable ended on ${gtfs.validTo}`);
assert.ok(![...gtfs.routes.values()].some((r) => r.short === ''), 'a line without a number');

const { vehicles, live } = await TCAT.refresh();
console.log(`temps réel : ${vehicles.length} bus, ${live.size} courses suivies`);
for (const v of vehicles) {
  assert.ok(v.lat > 47.9 && v.lat < 48.7 && v.lon > 3.6 && v.lon < 4.5, `bus hors zone: ${v.lat},${v.lon}`);
  assert.ok(v.time > Date.now() / 1000 - 3600, `position trop vieille: ${v.id}`);
}

// Departures at the stops the running buses serve: the whole chain, on today's data.
const now = new Date();
let shown = 0, withLive = 0;
for (const s of gtfs.stations.values()) {
  const deps = gtfs.departures(s.id, now, live, { count: 5 });
  for (const d of deps) {
    assert.ok(d.time >= Math.floor(now.getTime() / 1000) - 30, `${s.name}: un bus déjà parti`);
    assert.ok(d.time <= Math.floor(now.getTime() / 1000) + 4 * 3600, `${s.name}: au-delà de 4 h`);
    assert.ok(d.terminus.length > 0 && d.route.short.length > 0, `${s.name}: course incomplète`);
    assert.ok(d.delay == null || Math.abs(d.delay) < 2 * 3600, `${s.name}: retard aberrant ${d.delay}`);
    if (d.delay != null) withLive++;
  }
  if (deps.length) shown++;
}
console.log(`départs : ${shown} arrêts desservis dans les 4 h, dont ${withLive} passages en temps réel`);
assert.ok(shown > 50, 'aucun arrêt ne liste de bus : horaires ou calendrier cassés');
console.log('ok');
