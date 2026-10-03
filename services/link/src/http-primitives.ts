// These helpers neither authenticate nor parse JSON. Callers retain the exact
// raw body, decoder/BOM policy, limit units and error mapping of their protocol.
export async function readByteStream(
  body: ReadableStream<Uint8Array> | null,
  maximum: number,
  tooLarge: () => never,
): Promise<Uint8Array> {
  if (!body) return new Uint8Array();
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let count = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      count += next.value.length;
      if (count > maximum) {
        await reader.cancel();
        return tooLarge();
      }
      chunks.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

export function privateJSON(body: unknown, status = 200, headers?: Record<string, string>): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store", "x-content-type-options": "nosniff", ...headers },
  });
}
