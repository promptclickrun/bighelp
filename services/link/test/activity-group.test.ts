import { describe, expect, it } from "vitest";
import { activityMoment, activityMomentAlert, aggregateActivityRows, NATIVE_ROW_ID } from "../src/activity-group.js";

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

  it("gives sealed detail to the rows the card shows first, and never passes Apple's limit", () => {
    const appRow = (i: number) => `native-${i.toString(16).padStart(64, "0")}`;
    const sealed = "s".repeat(1200);
    const active = Array.from({ length: 64 }, (_, i) => ({
      ...row(appRow(i), i === 9 ? "waiting" : "using_tool"), timestamp: 1792854000, activeSubagentCount: 99, sealed,
    }));
    const result = aggregateActivityRows(active, 1792854000);
    expect(result.sessions[0]).toMatchObject({ id: appRow(9), sealed });
    expect(result.sessions.filter((value) => value.sealed).length).toBeLessThan(5);
    expect(result.sessions[4]).not.toHaveProperty("sealed");
    const apns = { aps: { timestamp: 1792854000, event: "update", "stale-date": 1792854120,
      "content-state": { ...result, groupId: `activity_${"g".repeat(43)}` } } };
    expect(new TextEncoder().encode(JSON.stringify(apns)).byteLength).toBeLessThanOrEqual(4000);
    // Rows without detail are what they were.
    expect(aggregateActivityRows([row("a", "thinking")], 101).sessions[0]).not.toHaveProperty("sealed");
    const five = aggregateActivityRows(Array.from({ length: 5 }, (_, i) => ({ ...row(appRow(i), "thinking"), sealed: "s".repeat(500) })), 101);
    expect(five.sessions.every((value) => value.sealed)).toBe(true);
  });

  it("ends only after every row is terminal", () => {
    expect(aggregateActivityRows([row("a", "completed"), row("b", "failed")], 101).phase).toBe("failed");
  });

  it("leaves the output as it was when no row leads", () => {
    const result = aggregateActivityRows([row("a", "thinking")], 101);
    const expected = {
      phase: "thinking", currentAction: "", progress: 0, completedSteps: 0, activeSubagentCount: 0,
      latestTool: null, timestamp: 101, activeCount: 1, activeRows: ["a"],
      sessions: [{ id: "a", phase: "thinking", timestamp: 100, activeSubagentCount: 0 }],
    };
    expect(JSON.stringify(result)).toBe(JSON.stringify(expected));
    expect(result).not.toHaveProperty("lead");
    // A lead that is not in the group changes nothing either.
    expect(aggregateActivityRows([row("a", "thinking")], 101, "missing")).toEqual(expected);
  });

  it("puts the leading row first, finished or not, and names it", () => {
    const result = aggregateActivityRows([row("a", "thinking"), row("b", "waiting"), row("c", "completed")], 101, "c");
    expect(result.lead).toBe("c");
    expect(result.sessions.map((value) => value.id)).toEqual(["c", "b", "a"]);
    // Which phase the card shows still comes from the work that is left.
    expect(result.phase).toBe("waiting");
    expect(result.activeCount).toBe(2);
  });

  it("keeps the leading row's sealed detail first when the push is tight", () => {
    const appRow = (i: number) => `native-${i.toString(16).padStart(64, "0")}`;
    const sealed = "s".repeat(1200);
    const rows = Array.from({ length: 64 }, (_, i) => ({
      ...row(appRow(i), i === 9 ? "waiting" : "using_tool"), timestamp: 1792854000, activeSubagentCount: 99, sealed,
    }));
    const result = aggregateActivityRows(rows, 1792854000, appRow(40));
    expect(result.lead).toBe(appRow(40));
    expect(result.sessions[0]).toMatchObject({ id: appRow(40), sealed });
    expect(result.sessions[1]).toMatchObject({ id: appRow(9) });
    expect(result.sessions.filter((value) => value.sealed).length).toBeLessThan(5);
    const apns = { aps: { timestamp: 1792854000, event: "update", "stale-date": 1792854120,
      alert: activityMomentAlert("waiting"), "content-state": { ...result, groupId: `activity_${"g".repeat(43)}` } } };
    expect(new TextEncoder().encode(JSON.stringify(apns)).byteLength).toBeLessThanOrEqual(4000);
  });

  it("finds a moment only when a row changes into waiting, completed or failed", () => {
    const state = (phase: string) => row("a", phase);
    expect(activityMoment(state("thinking"), state("waiting"))).toEqual({ row: "a", kind: "waiting" });
    expect(activityMoment(state("using_tool"), state("completed"))).toEqual({ row: "a", kind: "completed" });
    expect(activityMoment(state("waiting"), state("failed"))).toEqual({ row: "a", kind: "failed" });
    expect(activityMoment(state("waiting"), state("waiting"))).toBeNull();
    expect(activityMoment(state("completed"), state("completed"))).toBeNull();
    expect(activityMoment(state("waiting"), state("thinking"))).toBeNull();
    expect(activityMoment(state("thinking"), state("responding"))).toBeNull();
  });

  it("words each alert the same, and never from a chat", () => {
    expect(activityMomentAlert("waiting")).toEqual({ title: "Bighelp", body: "A chat needs you." });
    expect(activityMomentAlert("completed")).toEqual({ title: "Bighelp", body: "A chat finished." });
    expect(activityMomentAlert("failed")).toEqual({ title: "Bighelp", body: "A chat could not finish." });
  });
});
