import { getProfile } from './other';           // 1 IMPORT - must not be a call
import type { getProfile as T } from './t';     // 2 IMPORT

// getProfile(fake) in a line comment                        <- 4 COMMENT
/** getProfile(fake) in a jsdoc block */                      // 5 COMMENT
const s1 = "getProfile(fake)";                  // 6 STRING - must not be a call
const s2 = `tpl ${'getProfile'} literal`;       // 7 STRING

interface Shape {
  getProfile: () => void;                       // 10 TYPE MEMBER - not a call
}
type Fn = { getProfile(): void };               // 12 TYPE MEMBER

class Other {
  async getProfile(id: string) {                // 15 DEF (different class!)
    return this.inner.getProfile(id);           // 16 CALL via this.inner
  }
}

const obj = { getProfile };                     // 20 REF shorthand

function realCaller() {
  svc.getProfile(1);                            // 23 CALL
  svc?.getProfile(2);                           // 24 CALL optional chain
  svc!.getProfile(3);                           // 25 CALL non-null
  (svc as any).getProfile(4);                   // 26 CALL through cast
  const { getProfile: alias } = svc;            // 27 REF destructure
  getProfile(5);                                // 28 CALL bare
  const fn = svc.getProfile;                    // 29 REF not invoked
  arr.map(x => svc.getProfile(x));              // 30 CALL inside callback
  return svc.getProfile.bind(svc);              // 31 REF .bind
}

export const arrowCaller = async () => {
  await svc.getProfile(6);                      // 35 CALL in arrow
};

router.get('/x', getProfile);                   // 38 REF handler registration
