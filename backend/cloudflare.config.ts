import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "nanofly-api",
		compatibilityDate: "2026-10-19",
		entrypoint,
		env: {
			// Routes for a week, and each flight's last known position.
			// cf deploy makes the namespace the first time.
			FLIGHTS: bindings.kv(),
			// OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET, an OpenSky Network
			// API client, may be set as the Worker's secrets: then OpenSky
			// gives ten times the requests a day. Not declared here, as
			// declared secrets are required.
		},
	},
});
