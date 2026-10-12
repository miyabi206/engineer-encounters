import { createHandler } from "./handler.ts";

Deno.serve(createHandler({ fetch, env: (name) => Deno.env.get(name), now: Date.now }));
