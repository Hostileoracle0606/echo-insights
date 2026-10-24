// A small JSON Schema (2020-12) checker for the keywords the contracts in
// /contracts use. The infra package has no schema dependency, and this keeps
// it that way; an unsupported keyword fails loudly instead of passing.

const supported = new Set([
  "$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum",
  "required", "properties", "items", "minItems", "maxItems", "minLength", "maxLength",
  "minimum", "pattern", "format", "allOf", "if", "then",
]);

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

function matchesType(value, type) {
  const actual = typeOf(value);
  return actual === type || (type === "number" && actual === "integer");
}

function resolve(root, ref) {
  if (!ref.startsWith("#/")) throw new Error(`unsupported $ref ${ref}`);
  return ref
    .slice(2)
    .split("/")
    .reduce((node, key) => {
      if (!node || !(key in node)) throw new Error(`unresolved $ref ${ref}`);
      return node[key];
    }, root);
}

export function validate(root, value, schema = root, path = "$") {
  const errors = [];
  for (const key of Object.keys(schema)) {
    if (!supported.has(key)) throw new Error(`unsupported schema keyword ${key} at ${path}`);
  }
  if (schema.$ref) errors.push(...validate(root, value, resolve(root, schema.$ref), path));
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((type) => matchesType(value, type))) {
      return [...errors, `${path}: expected ${types.join("|")}, got ${typeOf(value)}`];
    }
  }
  if ("const" in schema && JSON.stringify(value) !== JSON.stringify(schema.const)) {
    errors.push(`${path}: expected ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum && !schema.enum.some((item) => JSON.stringify(item) === JSON.stringify(value))) {
    errors.push(`${path}: ${JSON.stringify(value)} not in enum`);
  }
  if (typeof value === "string") {
    const length = [...value].length;
    if (schema.minLength != null && length < schema.minLength) errors.push(`${path}: too short`);
    if (schema.maxLength != null && length > schema.maxLength) errors.push(`${path}: too long`);
    if (schema.pattern && !new RegExp(schema.pattern, "u").test(value)) {
      errors.push(`${path}: does not match ${schema.pattern}`);
    }
    if (schema.format === "date-time" && Number.isNaN(Date.parse(value))) {
      errors.push(`${path}: not a date-time`);
    }
  }
  if (typeof value === "number" && schema.minimum != null && value < schema.minimum) {
    errors.push(`${path}: below ${schema.minimum}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems != null && value.length < schema.minItems) errors.push(`${path}: too few items`);
    if (schema.maxItems != null && value.length > schema.maxItems) errors.push(`${path}: too many items`);
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(...validate(root, item, schema.items, `${path}[${index}]`));
      });
    }
  }
  if (typeOf(value) === "object") {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push(`${path}: missing ${key}`);
    }
    for (const [key, child] of Object.entries(schema.properties ?? {})) {
      if (key in value) errors.push(...validate(root, value[key], child, `${path}.${key}`));
    }
  }
  for (const child of schema.allOf ?? []) errors.push(...validate(root, value, child, path));
  if (schema.if && validate(root, value, schema.if, path).length === 0 && schema.then) {
    errors.push(...validate(root, value, schema.then, path));
  }
  return errors;
}
