import { describe, expect, it } from "vitest";
import { networkKey, networkPrefix } from "../src/network.js";

describe("networkPrefix", () => {
  it.each([
    ["203.0.113.7", "203.0.113.7"],
    ["2001:db8:1:2:aaaa:bbbb:cccc:dddd", "2001:db8:1:2::/64"],
    ["2001:0DB8:0001:0002:0000:0000:0000:0042", "2001:db8:1:2::/64"],
    ["2001:db8:1:2::1", "2001:db8:1:2::/64"],
    ["2001:db8::1", "2001:db8:0:0::/64"],
    ["::1", "0:0:0:0::/64"],
    ["fe80::1%en0", "fe80:0:0:0::/64"],
    ["::ffff:203.0.113.7", "203.0.113.7"],
    ["64:ff9b::203.0.113.7", "64:ff9b:0:0::/64"],
  ])("%s -> %s", (address, expected) => {
    expect(networkPrefix(address)).toBe(expected);
  });

  it("falls back to the text for something that is not an address", () => {
    expect(networkPrefix("not:an:address")).toBe("not:an:address");
    expect(networkPrefix("1:2:3:4:5:6:7:8:9")).toBe("1:2:3:4:5:6:7:8:9");
  });
});

describe("networkKey", () => {
  it("is null without a secret or an address", async () => {
    expect(await networkKey(undefined, "203.0.113.7")).toBeNull();
    expect(await networkKey("", "203.0.113.7")).toBeNull();
    expect(await networkKey("secret", null)).toBeNull();
  });

  it("is 32 hex characters and does not contain the address", async () => {
    const key = await networkKey("secret", "203.0.113.7");
    expect(key).toMatch(/^[0-9a-f]{32}$/);
  });

  it("depends on the secret", async () => {
    expect(await networkKey("one", "203.0.113.7")).not.toBe(await networkKey("two", "203.0.113.7"));
  });
});
