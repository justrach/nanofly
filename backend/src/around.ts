// The planes around a point (those near the one followed): adsb.lol's,
// rounded so phones looking at about the same place share one answer.
//
// OpenSky isn't asked from here: it doesn't answer Cloudflare's Workers
// (its requests time out, a 522), so the app asks it directly.
import { answer, recall, remember } from "./cache.ts";
import { adsbPoint, get, slim } from "./upstream.ts";

const json = "application/json";
const memory_s = 10;

function round(v: number, step: number): number {
	return Math.round(v / step) * step;
}

/** GET /v1/point/:lat/:lon/:nm, the planes within nm nautical miles. */
export async function point(lat_s: string, lon_s: string, nm_s: string): Promise<Response> {
	const lat = Number(lat_s);
	const lon = Number(lon_s);
	const nm = Number(nm_s);
	if (!(Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && nm > 0)) return answer({ status: 400, body: '{"error":"point"}', type: json }, "error", 0);
	const p = { lat: round(lat, 0.1).toFixed(1), lon: round(lon, 0.1).toFixed(1), nm: Math.min(250, Math.max(10, Math.ceil(nm / 10) * 10)) };
	const key = `point:${p.lat}/${p.lon}/${p.nm}`;
	const m = recall(key, memory_s);
	if (m) return answer(m, "memory", memory_s);
	const got = await get(adsbPoint(Number(p.lat), Number(p.lon), p.nm), 10);
	const s = got.ok ? slim(got.body) : null;
	if (!s) return answer({ status: got.status || 502, body: `{"error":"adsb.lol","status":${got.status}}`, type: json }, "error", 0);
	const body = JSON.stringify(s);
	remember(key, 200, body, json);
	return answer({ status: 200, body, type: json }, "adsb.lol", memory_s);
}
