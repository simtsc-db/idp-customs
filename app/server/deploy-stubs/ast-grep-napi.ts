// Deploy stub for @ast-grep/napi (dev-only); throws if ever called.
const unavailable = (): never => {
  throw new Error('@ast-grep/napi is not available in the production bundle');
};
export const Lang = new Proxy({}, { get: () => 'unavailable' });
export const parse = unavailable;
export const parseAsync = unavailable;
export const findInFiles = unavailable;
