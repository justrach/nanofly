// The planes over an area: adsb.lol's around a point (the planes near the
// one followed) and OpenSky's over a box (where adsb.lol hears nothing),
// rounded so phones looking at about the same place share one answer.
import { answer, keep, now, recall, remember } from "./cache.ts";
import { adsbPoint, get, opensky_token_url, openskyStates, slim, user_agent } from "./upstream.ts";

const json = "application/json";
const memory_s = 10;

function round(v: number, step: number): number {
	return Math.round(v / step) * step;
}

function bad(what: string): Response {
	return answer({ status: 400, body: `{"error":"${what}"}`, type: json }, "error", 0);
}

/** GET /v1/point/:lat/:lon/:nm, the planes within nm nautical miles. */
export async function point(lat_s: string, lon_s: string, nm_s: string): Promise<Response> {
	const lat = Number(lat_s);
	const lon = Number(lon_s);
	const nm = Number(nm_s);
	if (!(Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && nm > 0)) return bad("point");
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

type Token = { token: string; until: number };
let token: Token | null = null;

/** The Worker's OpenSky client, when its secrets are set. */
type OpenSkyClient = { OPENSKY_CLIENT_ID?: string; OPENSKY_CLIENT_SECRET?: string };

/** OpenSky's token for the Worker's API client, if it has one. */
async function openskyToken(all: Env, ctx: ExecutionContext): Promise<string | null> {
	const env = all as Env & OpenSkyClient;
	if (!env.OPENSKY_CLIENT_ID || !env.OPENSKY_CLIENT_SECRET) return null;
	if (token && token.until > now() + 60) return token.token;
	const kept = await env.FLIGHTS.get<Token>("opensky:token", "json");
	if (kept && kept.until > now() + 60) return (token = kept).token;
	try {
		const r = await fetch(opensky_token_url, {
			method: "POST",
			headers: { "User-Agent": user_agent, "Content-Type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({ grant_type: "client_credentials", client_id: env.OPENSKY_CLIENT_ID, client_secret: env.OPENSKY_CLIENT_SECRET }),
			signal: AbortSignal.timeout(10_000),
		});
		if (!r.ok) return null;
		const t = (await r.json()) as { access_token?: string; expires_in?: number };
		if (!t.access_token) return null;
		const life = t.expires_in ?? 1800;
		token = { token: t.access_token, until: now() + life };
		keep(ctx, env.FLIGHTS, "opensky:token", JSON.stringify(token), life - 60);
		return token.token;
	} catch {
		return null;
	}
}

/** GET /v1/opensky?lamin=&lomin=&lamax=&lomax=, OpenSky's states over a box. */
export async function opensky(env: Env, ctx: ExecutionContext, q: URLSearchParams): Promise<Response> {
	const raw = ["lamin", "lomin", "lamax", "lomax"].map((k) => q.get(k)?.trim() ?? "");
	// Number("") is 0: a missing bound isn't one.
	if (raw.some((x) => x === "")) return bad("box");
	const v = raw.map(Number);
	if (v.some((x) => !Number.isFinite(x)) || Math.abs(v[0]) > 90 || Math.abs(v[2]) > 90 || Math.abs(v[1]) > 180 || Math.abs(v[3]) > 180 || v[0] > v[2] || v[1] > v[3]) return bad("box");
	const box = { lamin: round(v[0], 0.1), lomin: round(v[1], 0.1), lamax: round(v[2], 0.1), lomax: round(v[3], 0.1) };
	const key = `opensky:${box.lamin}/${box.lomin}/${box.lamax}/${box.lomax}`;
	const m = recall(key, memory_s);
	if (m) return answer(m, "memory", memory_s);
	const t = await openskyToken(env, ctx);
	const got = await get(openskyStates(box), 20, t ? { Authorization: `Bearer ${t}` } : {});
	if (got.status === 401) {
		token = null;
		ctx.waitUntil(env.FLIGHTS.delete("opensky:token").catch(() => {}));
	}
	if (!got.ok) return answer({ status: got.status || 502, body: `{"error":"opensky","status":${got.status}}`, type: json }, "error", 0);
	remember(key, 200, got.body, json);
	return answer({ status: 200, body: got.body, type: json }, "opensky", memory_s);
}
