import { describe, expect, it } from "vitest";
import { aggregateActivityRows, NATIVE_ROW_ID } from "../src/activity-group.js";

describe("one Live Activity for several chats", () => {
  const row = (id: string, phase: string) => ({ id, phase, timestamp: 100, activeSubagentCount: 0 });
  it("does not end the shared card when only one chat finishes", () => {
    const result = aggregateActivityRows([row("a", "completed"), row("b", "thinking")], 101);
    expect(result.activeCount).toBe(1);
    expect(result.phase).toBe("thinking");
    expect(result.sessions.map((value) => value.id)).toEqual(["b", "a"]);
  });
  it("prioritizes attention, bounds the payload and preserves total count", () => {
    const result = aggregateActivityRows(Array.from({ length: 64 }, (_, i) => row(`native-${String(i).padStart(43, "a")}`, i === 63 ? "waiting" : "thinking")), 101);
    expect(result.activeCount).toBe(64);
    expect(result.sessions).toHaveLength(5);
    expect(result.sessions[0]?.id).toBe(`native-${"63".padStart(43, "a")}`);
    expect(JSON.stringify(result).length).toBeLessThan(3500);
  });
  it("carries bounded membership for hidden active rows without including terminal history", () => {
    const active = Array.from({ length: 64 }, (_, i) => ({
      ...row(`native-${String(i).padStart(43, "a")}`, "using_tool"),
      timestamp: 1792854000, activeSubagentCount: 99, latestTool: "漢".repeat(64),
    }));
    const result = aggregateActivityRows([...active,
      row(`native-${"z".repeat(43)}`, "completed"), row(`native-${"y".repeat(43)}`, "failed")], 1792854000);
    expect(result.activeRows).toHaveLength(64);
    expect(new Set(result.activeRows).size).toBe(64);
    expect(result.activeRows).toEqual([...result.activeRows].sort());
    expect(result.activeRows).toContain("63".padStart(16, "a"));
    expect(result.activeRows).not.toContain("z".repeat(16));
    expect(result.activeRows).not.toContain("y".repeat(16));
    const apns = { aps: { timestamp: 1792854000, event: "update", "stale-date": 1792854120,
      "content-state": { ...result, groupId: `native-${"g".repeat(43)}` } } };
    expect(new TextEncoder().encode(JSON.stringify(apns)).byteLength).toBeLessThan(4096);
  });

  it("accepts the row IDs the app sends and keeps their payload under Apple's limit", () => {
    // The app names a row "native-" and the SHA-256 of its chat in hex (71 characters).
    const appRow = (i: number) => `native-${i.toString(16).padStart(64, "0")}`;
    expect(NATIVE_ROW_ID.test(appRow(1))).toBe(true);
    expect(NATIVE_ROW_ID.test(`native-${"r".repeat(43)}`)).toBe(true);
    expect(NATIVE_ROW_ID.test(`native-${"A".repeat(64)}`)).toBe(false);
    expect(NATIVE_ROW_ID.test(`native-${"0".repeat(63)}`)).toBe(false);
    const active = Array.from({ length: 64 }, (_, i) => ({
      ...row(appRow(i), "using_tool"), timestamp: 1792854000, activeSubagentCount: 99, latestTool: "漢".repeat(64),
    }));
    const result = aggregateActivityRows(active, 1792854000);
    expect(result.sessions[0]?.id).toMatch(NATIVE_ROW_ID);
    const apns = { aps: { timestamp: 1792854000, event: "update", "stale-date": 1792854120,
      "content-state": { ...result, groupId: `activity_${"g".repeat(43)}` } } };
    expect(new TextEncoder().encode(JSON.stringify(apns)).byteLength).toBeLessThan(4096);
  });

  it("ends only after every row is terminal", () => {
    expect(aggregateActivityRows([row("a", "completed"), row("b", "failed")], 101).phase).toBe("failed");
  });
});
