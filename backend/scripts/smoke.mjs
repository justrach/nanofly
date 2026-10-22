// Checks a running nanofly-api against the live sources: every route, its
// caching, and its answers to bad requests.
//
//   node scripts/smoke.mjs http://localhost:5173
//   node scripts/smoke.mjs https://nanofly-api.<subdomain>.workers.dev
//
// Live flights come and go: a flight in the air is found first (FLIGHTS).
const base = (process.argv[2] ?? "http://localhost:5173").replace(/\/$/, "");
const FLIGHTS = ["SIA22", "SIA21", "QFA1", "QFA2", "BAW15", "BAW16", "UAE1", "UAE2", "DLH400", "AFR22", "JAL5", "ANA8", "UAL1", "DAL1"];

let failed = 0;
function check(name, ok, detail = "") {
	console.log(`${ok ? "ok  " : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
	if (!ok) failed++;
}

async function get(path, init) {
	const t = Date.now();
	const r = await fetch(base + path, init);
	const body = await r.text();
	return { status: r.status, source: r.headers.get("x-nanofly-source"), type: r.headers.get("content-type"), body, ms: Date.now() - t };
}

function json(s) {
	try {
		return JSON.parse(s);
	} catch {
		return null;
	}
}

const root = await get("/");
check("GET / names the API", root.status === 200 && json(root.body)?.name === "nanofly-api");

// A flight adsb.lol hears now.
let cs = null;
for (const c of FLIGHTS) {
	const r = await get(`/v1/callsign/${c}`);
	if (r.status === 200 && json(r.body)?.ac?.length > 0) {
		cs = c;
		break;
	}
}
check("a flight in the air is found", cs !== null, cs ?? "none of " + FLIGHTS.join(" "));
if (cs) {
	const again = await get(`/v1/callsign/${cs}`);
	check("asked again, from memory", again.source === "memory", `${again.source}, ${again.ms} ms`);
	const ac = json(again.body)?.ac?.[0] ?? {};
	check("only the fields the app reads", !("emergency" in ac) && "lat" in ac && "seen_pos" in ac, Object.keys(ac).join(","));
	const lower = await get(`/v1/callsign/${cs.toLowerCase()}`);
	check("a callsign in lower case", lower.status === 200 && json(lower.body)?.ac?.length > 0, lower.source);
	const routes = await get(`/v1/routes/${cs.slice(0, 3)}`);
	check(`routes of ${cs.slice(0, 3)} name ${cs}`, routes.status === 200 && routes.body.split("\n").some((l) => l.startsWith(cs + ",")), `${routes.source}, ${routes.body.length} bytes`);
	const p = json(again.body).ac[0];
	const point = await get(`/v1/point/${p.lat}/${p.lon}/100`);
	check("the planes around it", point.status === 200 && json(point.body)?.ac?.length > 0, `${json(point.body)?.ac?.length} planes, ${point.source}`);
	const near = await get(`/v1/point/${p.lat + 0.01}/${p.lon - 0.01}/95`);
	check("about the same place shares the answer", near.source === "memory", near.source);
	const box = `lamin=${Math.floor(p.lat) - 2}&lomin=${Math.floor(p.lon) - 2}&lamax=${Math.ceil(p.lat) + 2}&lomax=${Math.ceil(p.lon) + 2}`;
	const sky = await get(`/v1/opensky?${box}`);
	const states = json(sky.body)?.states ?? [];
	check("OpenSky over a box", sky.status === 200 && Array.isArray(states), `${states.length} states, ${sky.ms} ms, ${sky.status}`);
}

const unknown = await get("/v1/routes/ZZZ");
check("an airline without routes: 404", unknown.status === 404, unknown.source);
const unheard = await get("/v1/callsign/ZZZ9999");
check("a callsign not flying: 200, no aircraft", unheard.status === 200 && json(unheard.body)?.ac?.length === 0, unheard.source);
for (const [path, status] of [
	["/v1/callsign/no%20way", 400],
	["/v1/callsign/ABCDEFGHIJ", 400],
	["/v1/routes/SIAX", 400],
	["/v1/point/95/0/10", 400],
	["/v1/point/0/0/0", 400],
	["/v1/point/a/b/c", 400],
	["/v1/opensky?lamin=1", 400],
	["/v1/opensky?lamin=10&lomin=10&lamax=0&lomax=20", 400],
	["/v1/nothing", 404],
	["/v2/callsign/SIA22", 404],
]) {
	const r = await get(path);
	check(`${path}: ${status}`, r.status === status, String(r.status));
}
const post = await get("/v1/callsign/SIA22", { method: "POST" });
check("POST: 405", post.status === 405, String(post.status));

console.log(failed ? `\n${failed} failed` : "\nall passed");
process.exit(failed ? 1 : 0);
