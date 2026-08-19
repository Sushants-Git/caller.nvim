import alpha from './svc_a';
import { beta } from './svc_b';
import { getThing } from './free_fn';
import { Beta } from './svc_b';

class Sub extends Beta {}
const sub = new Sub();

class Holder {
  a: Alpha = alpha;

  run() {
    alpha.getThing('1');      // 13 class:Alpha  (default import -> new Alpha())
    beta.getThing('2');       // 14 class:Beta   (named import -> new Beta())
    getThing('3');            // 15 module:free_fn.ts
    this.a.getThing('4');     // 16 class:Alpha  (typed class field)
    sub.getThing('5');        // 17 class:Sub    (matches Beta via extends)
  }
}
