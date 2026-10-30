// Where a host's report came from: its country and, in the United States, its state. Cloudflare looks both up from
// the connection at its edge and hands the Worker two-letter codes. The Worker never sees a city, a postal code or
// coordinates from here, and the address itself stays out of this file. App and relay batches get none of this.

const COUNTRY = /^[A-Z]{2}$/;
// Cloudflare's codes for an unknown country and for Tor. Neither is a place.
const NOT_A_COUNTRY = new Set(["XX", "T1"]);
// The 50 states and DC. Territories such as Puerto Rico arrive as their own country codes.
const US_STATES = new Set([
  "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
  "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR",
  "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
]);

export interface HostLocation {
  country?: string;
  usState?: string;
}

/** The country, and the state for the US, from the request's Cloudflare properties. Empty when unknown. */
export function hostLocation(cf: unknown): HostLocation {
  const props = typeof cf === "object" && cf !== null ? (cf as { country?: unknown; regionCode?: unknown }) : {};
  const country = typeof props.country === "string" ? props.country.trim().toUpperCase() : "";
  if (!COUNTRY.test(country) || NOT_A_COUNTRY.has(country)) return {};
  if (country !== "US") return { country };
  const state = typeof props.regionCode === "string" ? props.regionCode.trim().toUpperCase() : "";
  return US_STATES.has(state) ? { country, usState: state } : { country };
}
