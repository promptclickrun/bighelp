import { describe, expect, it } from "vitest";
import { parseEncryptedFrame } from "../src/frame.js";

describe("encrypted realtime frame contract", () => {
  it("preserves explicit transient presentation classification and rejects unknown classes", () => {
    const frame = {
      version: 1, type: "frame", id: "frame-presentation-0001", senderDeviceId: "host-one",
      senderEpoch: 1, sequence: 1, ack: 0, ciphertext: "ciphertext_base64url_0001",
      deliveryClass: "presentation",
    };
    expect(parseEncryptedFrame(JSON.stringify(frame))).toMatchObject({ deliveryClass: "presentation" });
    expect(() => parseEncryptedFrame(JSON.stringify({ ...frame, deliveryClass: "drop_everything" }))).toThrow();
  });

  it("accepts a bounded epoch and sequence envelope without inspecting ciphertext", () => {
    expect(
      parseEncryptedFrame(
        JSON.stringify({
          version: 1,
          type: "frame",
          id: "frame-coordinate-0001",
          senderDeviceId: "mobile-device-1",
          senderEpoch: 3,
          sequence: 9,
          ack: 8,
          ciphertext: "ciphertext_base64url_0001",
        }),
      ),
    ).toEqual({
      version: 1,
      type: "frame",
      id: "frame-coordinate-0001",
      senderDeviceId: "mobile-device-1",
      senderEpoch: 3,
      sequence: 9,
      ack: 8,
      ciphertext: "ciphertext_base64url_0001",
    });
  });

  it("rejects malformed and non-monotonic coordinates", () => {
    expect(() => parseEncryptedFrame("not-json")).toThrowError(
      expect.objectContaining({ code: "frame_invalid" }),
    );
    expect(() =>
      parseEncryptedFrame(
        JSON.stringify({
          version: 1,
          type: "frame",
          id: "frame-coordinate-0001",
          senderDeviceId: "mobile-device-1",
          senderEpoch: 1,
          sequence: 0,
          ack: 0,
          ciphertext: "ciphertext_base64url_0001",
        }),
      ),
    ).toThrowError(expect.objectContaining({ code: "frame_invalid" }));
  });

  it("accepts a serialized encrypted frame at the 4,000,000-character boundary", () => {
    const encoded = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-coordinate-0001",
      senderDeviceId: "mobile-device-1",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(3_999_855),
    });

    expect(encoded).toHaveLength(4_000_000);
    expect(parseEncryptedFrame(encoded).ciphertext).toHaveLength(3_999_855);
  });

  it("rejects a serialized encrypted frame one character over the boundary", () => {
    const encoded = JSON.stringify({
      version: 1,
      type: "frame",
      id: "frame-coordinate-0001",
      senderDeviceId: "mobile-device-1",
      senderEpoch: 1,
      sequence: 1,
      ack: 0,
      ciphertext: "x".repeat(3_999_856),
    });

    expect(encoded).toHaveLength(4_000_001);
    expect(() => parseEncryptedFrame(encoded)).toThrowError(
      expect.objectContaining({ code: "frame_too_large" }),
    );
  });
});
