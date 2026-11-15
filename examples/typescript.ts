// TypeScript tour for carne: run with `carne run examples/typescript.ts`.
// Types erase at load; only JavaScript semantics remain at runtime.

enum Direction { Up, Down = 2 }
type Point = { x: number; y?: number };
type Name = string | null;

namespace Shapes {
  export interface Circle { radius: number }
  export interface Rect { w: number; h: number }
  export type Shape = Circle | Rect;

  export function area(s: Shape): number {
    if ("radius" in s) {
      return Math.PI * s.radius * s.radius;
    }
    return s.w * s.h;
  }
}

function id<T>(x: T): T { return x; }

// Overloads: signatures erase, the implementation runs.
function fmt(x: string): string;
function fmt(x: number): string;
function fmt(x: any): string { return "fmt:" + String(x); }

class Counter {
  constructor(private count: number = 0) {}
  incr(step: number = 1): number {
    this.count += step;
    return this.count;
  }
}

abstract class Greeter {
  abstract greet(name: string): string;
  punctuate(s: string): string { return s + "!"; }
}
class HelloGreeter extends Greeter {
  greet(name: string): string { return this.punctuate("hi " + name); }
}

const p: Point = { x: 1 };
const maybe: Name = null;
const n = (maybe as string | null) ?? "fallback";
const c = new Counter(41);

console.log("dir:", Direction.Up, Direction.Down, Direction[2]);
console.log("circle:", Shapes.area({ radius: 2 }));
console.log("rect:", Shapes.area({ w: 3, h: 4 }));
console.log("id:", id<number>(41), id("hi"));
console.log("fmt:", fmt("a"), fmt(1));
console.log("counter:", c.incr(), c.incr(2));
console.log("greeter:", new HelloGreeter().greet("ada"));
console.log("point:", JSON.stringify(p), "maybe:", n);
console.log("satisfies:", ({ a: 1 } satisfies object).a);
console.log("non-null:", ("x" as string | null)! + "?");
