// nanofly's backend: one place the app asks after flights, so phones share
// answers (and adsb.lol's limits), and a flight's last known place outlives
// adsb.lol's hiccups.
//
//   GET /v1/callsign/:cs              where a flight is (adsb.lol's JSON)
//   GET /v1/routes/:icao              an airline's routes (standing data's CSV)
//   GET /v1/point/:lat/:lon/:nm       the planes around a point (adsb.lol's JSON)
//
// OpenSky isn't here: it doesn't answer Workers, so the app asks it.
import { live, routes } from "./flights.ts";
import { point } from "./around.ts";

function notFound(): Response {
	return Response.json({ error: "not found" }, { status: 404 });
}

export default {
	async fetch(request, env, ctx) {
		if (request.method !== "GET") return Response.json({ error: "GET only" }, { status: 405 });
		const url = new URL(request.url);
		const p = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
		if (p.length === 0) return Response.json({ name: "nanofly-api", version: 1 });
		if (p[0] !== "v1") return notFound();
		switch (p[1]) {
			case "callsign":
				return p.length === 3 ? live(env, ctx, p[2]) : notFound();
			case "routes":
				return p.length === 3 ? routes(env, ctx, p[2]) : notFound();
			case "point":
				return p.length === 5 ? point(p[2], p[3], p[4]) : notFound();
			default:
				return notFound();
		}
	},
} satisfies ExportedHandler<Env>;
