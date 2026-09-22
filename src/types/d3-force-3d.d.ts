declare module "d3-force-3d" {
  interface PositionForce {
    strength(s: number | ((d: unknown) => number)): PositionForce;
  }
  export function forceX(x?: number | ((d: unknown) => number)): PositionForce;
  export function forceY(y?: number | ((d: unknown) => number)): PositionForce;
}
