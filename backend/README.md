# nanofly-api

nanofly's backend: a Cloudflare Worker the app asks after flights instead of
asking each source itself. It answers in the shapes the app already reads,
so the app only changes where it asks (`-Dapi=...`).

- **Phones share answers.** A flight's position is kept a few seconds in
  memory, so many phones following it cost adsb.lol one request.
- **Routes are kept in KV for a week**: each airline's routes (standing
  data's CSV), and a day's note when an airline has none.
- **Each flight's last known position is kept in KV** (an hour). When
  adsb.lol fails or stops hearing a plane (over an ocean), the Worker
  answers with where it was last heard for ten minutes, its age grown
  ("heard 2m ago"), instead of nothing.
- **OpenSky's client stays here**, as the Worker's secrets, not in the app.

| Route | Answer |
|---|---|
| `GET /v1/callsign/:cs` | where a flight is: adsb.lol's JSON, only the fields the app reads |
| `GET /v1/routes/:icao` | an airline's routes: standing data's CSV |
| `GET /v1/point/:lat/:lon/:nm` | the planes around a point: adsb.lol's JSON, rounded so nearby asks share |
| `GET /v1/opensky?lamin=&lomin=&lamax=&lomax=` | OpenSky's states over a box |

`X-Nanofly-Source` says where an answer came from: `memory`, `kv`,
`kv-stale` (adsb.lol couldn't answer), `adsb.lol`, `standing-data`,
`opensky` or `error`.

## KV and its limits

KV takes one write a second per key, and the free plan 1,000 writes a day;
reads elsewhere in the world can be a minute old. So fresh positions are
never read from KV: it keeps routes, and each flight's last position,
written at most once a minute per flight by each isolate. A write turned
away is let go (the cache is a convenience). On a `*.workers.dev` address
the Cache API does nothing, so memory is the short-term cache.

## Develop and deploy

Made with [`cf`](https://developers.cloudflare.com/cf/), Cloudflare's CLI
(Node.js 22.18 or later). `cloudflare.config.ts` describes the Worker.

```sh
npm install
npm run dev          # cf dev: http://localhost:5173, with a local KV
npm run typecheck
npx cf deploy        # makes the FLIGHTS namespace the first time
```

An OpenSky API client, optional (then OpenSky allows ten times the requests
a day), is set as two secrets, `OPENSKY_CLIENT_ID` and
`OPENSKY_CLIENT_SECRET` (for `cf dev`, in `.dev.vars`). The OpenSky Network
asks that live products using its API have its written permission.

Then build the app against it:

```sh
cd ..
zig build -Dapi=https://nanofly-api.<your-subdomain>.workers.dev
NANOFLY_API=http://localhost:5173 ./zig-out/bin/nanofly   # the Mac app against cf dev
```
