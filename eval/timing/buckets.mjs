// Mirror of entityCountBucket in lib/logic/timing_marks.dart: an entity count
// as its order of magnitude (0, 1, 10, 100, 1000+).
export function entityCountBucket(count) {
  if (count <= 0) return 0;
  let bucket = 1;
  while (bucket < 1000 && count >= bucket * 10) bucket *= 10;
  return bucket;
}
