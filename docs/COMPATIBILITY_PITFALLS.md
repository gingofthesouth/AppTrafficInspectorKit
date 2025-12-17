### Functional Compatibility Checklist: iOS Client ↔︎ Mac Receiver

Use this checklist to verify that the rewritten Mac app is interoperable with the iOS client implementation (legacy Objective‑C Bagel client vs the new Swift plan).

## Bonjour service discovery
- **Service type must match**: Old iOS client browses `_Bagel._tcp`; new Swift plan uses `_AppTraffic._tcp`. Ensure the Mac app advertises/browses the same type.
- **Port**: 43435 on the Mac side (listener) and expected by iOS client. Confirm no NAT/firewall conflicts.
- **Domain**: iOS client uses empty domain (defaults to local). Mac typically advertises in `local.`. Make sure browse/advertise settings align.
- **Plist (iOS14+)**: Ensure `NSLocalNetworkUsageDescription` and `NSBonjourServices` include the chosen service type.

## Transport and connection
- **Role**: Mac app must be the TCP server; iOS connects as a client.
- **Resolution**: If using Network.framework, prefer `.service` endpoints (or resolve `NSNetService` before connecting). Avoid connecting to `.ipv4(.any)` or port `.any`.
- **IPv4/IPv6**: Mac listener should support both; iOS connect logic should handle whichever A/AAAA address is resolved.
- **Multiple clients**: If the Mac app expects multiple iOS clients, ensure listener accepts concurrent connections.

## Framing (critical)
- **Length prefix**: A fixed 8‑byte length header precedes each JSON packet.
  - Legacy iOS writes the raw `uint64_t` length without explicit byte‑order conversion (host endian). The new Swift plan proposes big‑endian.
  - Mac app must either:
    - Read in the agreed endianness (recommended: big‑endian across both sides), or
    - Implement a tolerant read that detects implausible sizes and falls back to swapped endianness.
- **Fragmentation**: TCP is a stream—read exactly 8 bytes for the header, then read exactly `length` bytes for the body, looping until complete.

## JSON schema and field types
- **Top‑level keys**: `packetId`, `requestInfo`, `project`, `device` must be present.
- **requestInfo fields** (names case‑sensitive):
  - `url` (string URL)
  - `requestHeaders` (object string→string)
  - `requestBody` (base64 string, may include line breaks in legacy)
  - `requestMethod` (string)
  - `responseHeaders` (object string→string, optional)
  - `responseData` (base64 string, optional, usually sent only at completion)
  - `statusCode` (legacy: string; new plan may be number). Mac should accept either or we standardize.
  - `startDate`, `endDate` (legacy: UNIX epoch seconds as number). New plan must not switch to ISO8601 unless the Mac app supports both.
- **Device/Project**: Expect `deviceId`, `deviceName`, `deviceDescription`, and `projectName` fields.
- **Base64 nuances**: Legacy iOS may emit base64 with 64‑char line breaks; decoders must ignore whitespace/newlines. New Swift default emits continuous base64—accept both.
- **Unknown fields**: Mac JSON parser should ignore unknown fields to allow forward compatibility (e.g., future `schemaVersion`).

## Event semantics (when packets are sent)
- **Events**: iOS sends at least three updates per request: start, response, completion.
- **Body streaming**: Legacy behavior accumulates response data and only includes `responseData` at completion. If the Mac UI expects incremental body chunks, it will not receive them unless the protocol is extended.

## Interception differences (risk awareness)
- **Old iOS**: private API swizzling (`__NSCFURLSessionTask`, `__NSCFURLLocalSessionConnection`) and NSURLConnection delegates.
- **New Swift plan**: currently mirrors that approach. Not a wire‑level change, but if interception changes to a `URLProtocol` approach later, Mac behavior remains unaffected as long as emitted packets are the same.

## Compression and encryption
- **Compression**: None in legacy. If the Mac app expects compressed payloads, disable or negotiate; otherwise, ensure it accepts plain JSON.
- **Encryption/TLS**: Legacy is plain TCP. If TLS is introduced on Mac, iOS must match (certificate pinning or trust model defined).

## Versioning and extensibility
- **Schema version**: Consider supporting an optional `schemaVersion` at the top level. Mac should default safely if absent.
- **Backward compatibility**: Mac app should be liberal in what it accepts (string vs number for `statusCode`, date formats, presence/absence of optional fields).

## Performance and limits
- **Large payloads**: Mac reader must handle large `length` values efficiently (stream decode, size caps, UI truncation). Avoid assuming small JSON bodies.
- **Backpressure**: If Mac cannot keep up, it should buffer responsibly or drop oldest packets; iOS does not implement flow control beyond TCP.

## Quick validation checklist
- [ ] Mac advertises/browses the same Bonjour service type as iOS.
- [ ] Mac listening port is 43435 and reachable on local network.
- [ ] Framing: 8‑byte length header parsed correctly (agreed endianness).
- [ ] JSON parser tolerates: base64 with/without line breaks; `statusCode` as string or number; UNIX epoch dates.
- [ ] Mac tolerates unknown fields and missing optional fields.
- [ ] Reads full frames over TCP (handles fragmentation and coalescing).
- [ ] Handles multiple simultaneous iOS connections.
- [ ] No assumption of compression or TLS unless explicitly enabled on both sides.
- [ ] UI/logic does not require incremental body chunks during transfer.

## Recommended alignment (to minimize incompatibilities)
- Adopt big‑endian for the 8‑byte length on both sides going forward; maintain a tolerant reader for legacy traffic.
- Standardize on UNIX epoch seconds for dates, and accept ISO8601 as a fallback if needed.
- Keep `statusCode` as number in new payloads; accept string in the Mac app for legacy.
- Normalize base64 decoding to ignore whitespace/newlines.



