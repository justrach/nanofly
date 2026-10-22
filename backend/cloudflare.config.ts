import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "nanofly-api",
		compatibilityDate: "2026-10-19",
		entrypoint,
		env: {
			// Routes for a week, and each flight's last known position
			// (the namespace nanofly-api-FLIGHTS; without an id, cf deploy
			// makes one).
			FLIGHTS: bindings.kv({ id: "c0bd7b228ed04dad947e2cf75dce7dcb" }),
		},
	},
});
