// What the Worker keeps: a few seconds in each isolate's memory (the Cache
// API does nothing on workers.dev), and in KV what outlives a request:
// routes, and the last place each flight was heard.

type Entry = { at: number; status: number; body: string; type: string };

const memory = new Map<string, Entry>();
const memory_max = 500;

export function now(): number {
	return Date.now() / 1000;
}

/** A remembered answer younger than `fresh_s` seconds. */
export function recall(key: string, fresh_s: number): Entry | undefined {
	const e = memory.get(key);
	if (!e) return undefined;
	if (now() - e.at > fresh_s) {
		memory.delete(key);
		return undefined;
	}
	return e;
}

export function remember(key: string, status: number, body: string, type: string): void {
	if (memory.size >= memory_max) memory.delete(memory.keys().next().value!);
	memory.set(key, { at: now(), status, body, type });
}

/** `e` as a response, saying where it came from. */
export function answer(e: { status: number; body: string; type: string }, source: string, max_age_s: number): Response {
	return new Response(e.body, {
		status: e.status,
		headers: {
			"Content-Type": e.type,
			"Cache-Control": `public, max-age=${max_age_s}`,
			"X-Nanofly-Source": source,
		},
	});
}

/** Writes to KV in the background; a write turned away (one a second per
 * key, the plan's writes a day) is let go: the cache is a convenience. */
export function keep(ctx: ExecutionContext, kv: KVNamespace, key: string, value: string, ttl_s: number): void {
	ctx.waitUntil(kv.put(key, value, { expirationTtl: Math.max(60, Math.round(ttl_s)) }).catch(() => {}));
}
