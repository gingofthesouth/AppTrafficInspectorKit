## Wire Contract (iOS client → Mac receiver)

### Transport
- Service discovery: Bonjour `_AppTraffic._tcp` in domain `local.` (empty domain in API means local)
- Role: Mac app listens (TCP server), iOS connects as client
- Port: 43435 (default on Mac receiver)

### Framing
- Each message: 8-byte big-endian length prefix followed by JSON payload
- TCP is a stream: receiver must read exactly 8 bytes (header), then `length` bytes (body). Handle fragmentation/coalescing.

### JSON envelope
Top-level object fields:
- `packetId` (string)
- `schemaVersion` (number, optional)
- `requestInfo` (object)
- `project` (object)
- `device` (object)

`requestInfo` fields:
- `url` (string)
- `requestHeaders` (object string→string)
- `requestBody` (base64 string, optional)
- `requestMethod` (string)
- `responseHeaders` (object string→string, optional)
- `responseData` (base64 string, optional; present on completion)
- `statusCode` (number; receiver should also accept string for legacy)
- `startDate` (number: UNIX epoch seconds)
- `endDate` (number: UNIX epoch seconds, optional)

`project` fields:
- `projectName` (string)

`device` fields:
- `deviceId` (string)
- `deviceName` (string)
- `deviceDescription` (string)

### Encoding strategies
- Dates: UNIX epoch seconds
- Data: base64 (no line breaks)

### Privacy & performance
- iOS may apply redaction and body-size limits; receivers should tolerate missing `responseData` or truncated payloads

### Compatibility notes
- Legacy clients may use host-endian length prefix and string `statusCode`; receivers should be tolerant when feasible


