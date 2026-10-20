# Bounded VNC performance capture

VNC performance signposts use subsystem `dev.sadiksaifi.Remora` and category `DynamicTracing`. The SDK disables this category unless a recording tool enables it. Disabled reads do not collect performance clocks or byte counters. Existing handshake and runtime failure summaries remain in category `VNC` and retain their previous meanings. A client generates its signpost ID lazily at its first enabled event, because the SDK returns a null ID while tracing is disabled. Each valid ID remains local to that client across recording detach and reattach.

Record only the process and time window needed. Create a private options file containing:

```json
{"os_signpost":{"dynamicTracingEnabledSubsystems":["dev.sadiksaifi.Remora"],"recordAllProcessesInSingleProcessMode":false}}
```

Then run:

```sh
xcrun xctrace record --instrument os_signpost --recording-options <options.json> --attach <pid> --time-limit 20s --output <private.trace>
```

These events contain geometry and numeric timings, but no pixels, text, endpoint, account, credentials, cryptographic material, keysyms or clipboard. Geometry can reveal window layout. Keep the recording private. Export the `os-signpost-arg` table to a file and validate an allowlist before displaying results. Do not print a trace TOC or process metadata.

## Numeric semantics

Every event carries one client signpost identifier and `seq`, the FramebufferUpdate message sequence since connection. All wall durations are integer microseconds from `CLOCK_UPTIME_RAW`. CPU duration uses `CLOCK_THREAD_CPUTIME_ID`. Neither clock changes the existing read deadline. Wait time includes descheduling and does not separate server production from network transfer.

`VNCUpdate` describes one message. It records `ok`, `declared_rects` (including the 65535 LastRect sentinel), `header_known`, `wire_rects` (all successfully read rectangle headers, including pseudo-encodings and LastRect), and `callbacks` (actual framebuffer sink calls). These counts can differ legally.

- `request_known` and `prefetched_start` qualify `req_to_ready_us`. It measures the last observed request write return to outer readiness. It is -1 when no recorded request exists or bytes were already buffered before the outer wait. It does not measure TCP first-byte arrival.
- `ready_to_header_us` ends after the three remaining update-header bytes are read. `message_us` ends at parser completion, before the trailing automatic incremental request. This includes control-only messages and pseudo-rectangles after the last pixel callback.
- `read_wait_us` sums wall time inside exact-read readiness waits. `logical_bytes` sums original requested lengths of successful exact reads. It includes message and rectangle headers, but excludes prefetched bytes belonging to future messages. `buffered_end` counts those remaining buffered bytes at parser completion.
- `cpu_us` spans readiness to parser completion. `callback_us` sums sink wall time. `area_sum` and `area_max` describe callback pixel areas; equal geometry does not establish equal pixels. `enc_mask` bits 0 through 6 mean Raw, CopyRect, Hextile, Zlib, ZRLE, Tight and other callback encodings.
- `requests_during` counts request writes before parser completion, excluding the trailing incremental. A resize/control path can legitimately make this positive. `inputs_during` counts successful key/pointer writes in that message, including writes from the in-read input service.
- On `ok=0`, all duration and byte fields are -1. Header/count fields retain known partial context. Partial successful callbacks remain counted. No completion duration is inferred from a failed read.

`VNCPixelRect` is emitted at entry to an actual framebuffer sink callback, not for every wire rectangle. `index` is the zero-based wire header index. `x`, `y`, `w`, `h` and signed `encoding` describe that callback. `rect_bytes` includes its 12-byte header and successfully read payload. `zrle_len` is the compressed length, or -1 for another encoding. ZRLE `header_to_len_us`, `len_to_body_us` and `body_to_callback_us` split header completion, length completion, final compressed-body exact-read completion and callback entry. Other encodings use -1. `rect_wait_us` includes header and payload waits. The decode-tail boundary is not the whole decoder CPU cost: inflation can occur between compressed chunks.

`VNCRequest` describes each actual FramebufferUpdateRequest write: `incremental`, `full_area` (request geometry equals the current whole desktop), `write_us` and `ok`. It does not record skipped writes. `VNCInput` records each actual key (`kind=1`) or pointer (`kind=2`) write and `ok`. Releases appear as their underlying writes; no semantic key or button value is recorded.

Performance context is separate from the first-failure record. Successful in-read input restores parser diagnostics without rolling back performance counters. Recording attached during an in-flight message starts complete-message measurement at the next outer read. Independent request/input events can appear sooner. A recording stopped mid-message can omit its completion event. An event is not a renderer presentation measurement.

## Public loopback verification

Build test products, then capture the retained public session fixture:

```sh
swift test --package-path Packages/RemoraKit --filter vncPerformanceTraceFixture
python3 Packages/RemoraKit/Tests/VNCSessionTests/Fixtures/verify_performance_trace.py <new-private-output-directory>
python3 Packages/RemoraKit/Tests/VNCSessionTests/Fixtures/verify_performance_trace.py <another-new-private-output-directory> --attach
```

The verifier uses Xcode's SwiftPM testing helper and an already-built public test bundle. Its default mode launches under bounded xctrace recording. The `--attach` mode first creates and connects the session with tracing disabled, then attaches to that same test process before the next peer message. Its test-only stdin barrier waits for the actual xctrace tracing-start notification; category enablement alone can precede collection. It verifies the same pixel bytes, input overlap and subsequent messages, while excluding the initial unrecorded update and request writes. The first recorded message correctly has unavailable request timing because its request preceded the recording. It supplies only SDK framework paths and an isolated test home. The fixture has a literal loopback peer, one connection and a ten-second peer deadline. Its independent persistent ZRLE stream covers two pixel rectangles, cursor/LastRect, a paced input/release, a prefetched empty update and a partial Raw EOF. The verifier checks exact numeric counts, logical bytes, geometry, sentinels and input overlap, plus delay lower bounds. It emits only a numeric receipt; raw tool output remains in the supplied directory. On the verified SDK, current-process OSLogStore returned no DynamicTracing signposts even during recording, so it is not used as a substitute for capture verification.
