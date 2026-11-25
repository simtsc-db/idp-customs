// Deploy-build stub for @ast-grep/napi (a native module AppKit uses only for
// dev-time type generation and lint). Production code never calls it; if it
// ever does, fail loudly instead of silently.
const unavailable = (): never => {
  throw new Error('@ast-grep/napi is not available in the production bundle');
};
export const Lang = new Proxy({}, { get: () => 'unavailable' });
export const parse = unavailable;
export const parseAsync = unavailable;
export const findInFiles = unavailable;
