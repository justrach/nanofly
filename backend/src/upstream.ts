// The sources nanofly's flights come from, asked from the Worker.

export const user_agent = "nanofly-api/0.1 (+https://github.com/justrach/nanofly)";

export type Got = { ok: boolean; status: number; body: string };

/** GETs `url`, giving up after `timeout_s`; a failure is status 0. */
export async function get(url: string, timeout_s: number, headers: Record<string, string> = {}): Promise<Got> {
	try {
		const r = await fetch(url, { headers: { "User-Agent": user_agent, ...headers }, signal: AbortSignal.timeout(timeout_s * 1000) });
		return { ok: r.ok, status: r.status, body: await r.text() };
	} catch {
		return { ok: false, status: 0, body: "" };
	}
}

export function adsbCallsign(cs: string): string {
	return `https://api.adsb.lol/v2/callsign/${cs}`;
}

export function adsbPoint(lat: number, lon: number, nm: number): string {
	return `https://api.adsb.lol/v2/point/${lat}/${lon}/${nm}`;
}

export function routesCsv(icao: string): string {
	return `https://raw.githubusercontent.com/vradarserver/standing-data/main/routes/schema-01/${icao[0]}/${icao}-all.csv`;
}


/** adsb.lol's fields the app reads, so answers stay small. */
const kept = ["hex", "flight", "r", "t", "alt_baro", "gs", "track", "true_heading", "baro_rate", "geom_rate", "lat", "lon", "seen_pos", "seen"];

/** adsb.lol's answer with only the fields kept, or null if it isn't one. */
export function slim(body: string): { ac: Record<string, unknown>[]; now: number } | null {
	let v: unknown;
	try {
		v = JSON.parse(body);
	} catch {
		return null;
	}
	if (typeof v !== "object" || v === null || !Array.isArray((v as { ac?: unknown }).ac)) return null;
	const o = v as { ac: Record<string, unknown>[]; now?: number };
	const ac = o.ac.map((a) => Object.fromEntries(kept.filter((k) => k in a).map((k) => [k, a[k]])));
	return { ac, now: typeof o.now === "number" ? o.now : Date.now() };
}
