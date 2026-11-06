import { describe, expect, it } from "vitest";

import { slugify } from "./journal-store";

describe("slugify", () => {
  it("gives names with no Latin letters a stable id", () => {
    expect(slugify("प्रिया")).toBe("प्रिया");
    expect(slugify("Иван")).toBe("иван");
    expect(slugify("李雷")).toBe("李雷");
    expect(slugify("Иван Петров")).toBe("иван-петров");
  });

  it("leaves the ids of Latin names as they were", () => {
    expect(slugify("Project Atlas")).toBe("project-atlas");
    expect(slugify("Héros")).toBe("heros");
    expect(slugify("O'Brien")).toBe("o-brien");
    expect(slugify("St. John")).toBe("st-john");
  });

  it("keeps an id to 60 whole characters", () => {
    expect(Array.from(slugify("李".repeat(80)))).toHaveLength(60);
  });
});
