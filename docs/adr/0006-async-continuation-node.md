# A node may continue the graph asynchronously, from an external callback

The Webhook node (`action.webhook`) issues an HTTP POST, which completes not inline but via a
completion callback some time later. It still needs to drive the graph onward — `On Success`
and `On Failure` exec outputs, plus `status` / `response` data outputs — so the user can chain
"webhook failed → flash the screen." We allow the node's `run` to start the request, return
immediately, and `ctx:Fire` its exec outputs **later, from the HTTP callback**, rather than
forcing the node to be fire-and-forget or inventing a new engine primitive for async.

This is legal without any engine change: `Graph:_makeCtx` builds `ctx` as a closure over the
node, the graph, and the current depth, and `ctx:Fire` just calls `graph:_fireOutput`. That
closure stays valid after `run` returns, and the RS3 client is single-threaded — the HTTP
callback is dispatched on the same thread as everything else — so a deferred `ctx:Fire`
synchronously propagates downstream at callback time, exactly as an inline `Fire` would. The
Webhook is the first **Async Node**; the concept is named in CONTEXT.md.

## Consequences

The trigger→…→webhook sweep **returns before** the webhook's success/failure fires. Anything
downstream of `On Success` / `On Failure` runs in a *later* turn, detached from the originating
event — correct for networking, but a genuine break from the until-now invariant that a Fire
completes the whole reachable subgraph synchronously. Trace/live-viz sees the continuation as a
separate firing episode, not part of the trigger's. `ctx.payload` is already nil downstream
(ADR-0009), so nothing that arrives via the callback should assume the original event data — the
node must stash anything it needs on `ctx.state` or emit it on its own data outputs before it
fires. Re-entrancy is bounded by the same single-threaded assumption: if that ever stops holding
(a threaded HTTP dispatch), deferred `Fire` would need marshalling back onto the main loop, and
this decision would have to be revisited.

The alternative, fire-and-forget (no continuation, errors only logged), was rejected because the
failure path is the point — a webhook silently failing to send an alert is worse than most
failures a game overlay has, and "tell me when my alert didn't go out" is a primary use case.
A dedicated async/await engine primitive was rejected as unnecessary given the closure already
supports deferred Fire; we keep the engine ignorant of async and let the node own its own timing.
