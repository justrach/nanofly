// A flight's route and where it is: the answers nanofly's tracker asks
// for, in the shapes it already reads (standing data's CSV, adsb.lol's
// JSON), cached in memory and KV.
import { answer, keep, now, recall, remember } from "./cache.ts";
import { adsbCallsign, get, routesCsv, slim } from "./upstream.ts";

const json = "application/json";
const csv = "text/csv; charset=utf-8";

/** Seconds an answer is kept in an isolate's memory. */
const live_memory_s = 5;
/** Each flight's position is written to KV at most this often by an
 * isolate (KV takes one write a second per key, and the free plan 1,000
 * writes a day). KV isn't asked for fresh positions: its reads can be a
 * minute old elsewhere. It keeps where a flight was last heard. */
const live_kv_every_s = 60;
const written = new Map<string, number>();
/** How long the last known position answers when adsb.lol fails (not
 * when it answers without the plane: then the app asks OpenSky). */
const live_stale_s = 600;
const live_kv_ttl_s = 3600;

const routes_ttl_s = 7 * 24 * 3600;
/** An airline without routes is asked again after a day. */
const missing_ttl_s = 24 * 3600;

type Heard = { at: number; body: string };

/** The kept answer, its aircraft's ages grown by the time since. */
function aged(h: Heard): string {
	const s = JSON.parse(h.body) as { ac: Record<string, unknown>[] };
	const dt = Math.max(0, now() - h.at);
	for (const a of s.ac) {
		if (typeof a.seen_pos === "number") a.seen_pos = Math.round((a.seen_pos + dt) * 10) / 10;
		if (typeof a.seen === "number") a.seen = Math.round((a.seen + dt) * 10) / 10;
	}
	return JSON.stringify(s);
}

/** GET /v1/callsign/:cs, adsb.lol's answer for a callsign. */
export async function live(env: Env, ctx: ExecutionContext, raw: string): Promise<Response> {
	const cs = raw.toUpperCase();
	if (!/^[A-Z0-9]{2,8}$/.test(cs)) return answer({ status: 400, body: '{"error":"callsign"}', type: json }, "error", 0);
	const key = `live:${cs}`;
	const m = recall(key, live_memory_s);
	if (m) return answer({ ...m, body: m.status === 200 ? aged(m) : m.body }, "memory", live_memory_s);

	const got = await get(adsbCallsign(cs), 8);
	const s = got.ok ? slim(got.body) : null;
	if (s && s.ac.length > 0) {
		const body = JSON.stringify(s);
		remember(key, 200, body, json);
		if (now() - (written.get(key) ?? 0) >= live_kv_every_s) {
			if (written.size >= 2000) written.clear();
			written.set(key, now());
			keep(ctx, env.FLIGHTS, key, JSON.stringify({ at: now(), body }), live_kv_ttl_s);
		}
		return answer({ status: 200, body, type: json }, "adsb.lol", live_memory_s);
	}
	// adsb.lol answers but doesn't hear it (over an ocean): said so, for the
	// app then asks OpenSky, which may.
	if (s) {
		const body = JSON.stringify(s);
		remember(key, 200, body, json);
		return answer({ status: 200, body, type: json }, "adsb.lol", live_memory_s);
	}
	// adsb.lol can't answer (down, slow, too many requests): where the
	// flight was last heard, if lately, and how long ago.
	const kept = await env.FLIGHTS.get<Heard>(key, "json");
	if (kept && now() - kept.at < live_stale_s) return answer({ status: 200, body: aged(kept), type: json }, "kv-stale", live_memory_s);
	return answer({ status: 502, body: `{"error":"adsb.lol","status":${got.status}}`, type: json }, "error", 0);
}

/** GET /v1/routes/:icao, an airline's routes (standing data's CSV). */
export async function routes(env: Env, ctx: ExecutionContext, raw: string): Promise<Response> {
	const icao = raw.toUpperCase();
	if (!/^[A-Z]{3}$/.test(icao)) return answer({ status: 400, body: "airline", type: csv }, "error", 0);
	const key = `routes:${icao}`;
	const m = recall(key, 3600);
	if (m) return answer(m, "memory", 3600);

	const kept = await env.FLIGHTS.get(key, { cacheTtl: 3600 });
	if (kept === "-") {
		remember(key, 404, "", csv);
		return answer({ status: 404, body: "", type: csv }, "kv", 3600);
	}
	if (kept) {
		remember(key, 200, kept, csv);
		return answer({ status: 200, body: kept, type: csv }, "kv", 3600);
	}

	const got = await get(routesCsv(icao), 15);
	if (got.ok && got.body.length > 0) {
		remember(key, 200, got.body, csv);
		keep(ctx, env.FLIGHTS, key, got.body, routes_ttl_s);
		return answer({ status: 200, body: got.body, type: csv }, "standing-data", 3600);
	}
	if (got.status === 404) {
		remember(key, 404, "", csv);
		keep(ctx, env.FLIGHTS, key, "-", missing_ttl_s);
		return answer({ status: 404, body: "", type: csv }, "standing-data", 3600);
	}
	return answer({ status: 502, body: "", type: csv }, "error", 0);
}
