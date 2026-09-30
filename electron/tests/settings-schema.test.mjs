// The settings window's schema, checked against itself and against the
// components that draw it. Run with `make ui-test` (Node's own test runner;
// no dependency).
//
// These are the mistakes that fail silently in the window: a condition on a
// key nothing defines is never true, an icon name that does not exist draws
// nothing, two rows with the same title confuse React's reconciliation, and
// the launch landing scrolls to a section that is not where it looks.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const { PAGES, PIPELINE_KEYS, PIPELINE_PRESETS } = await import("../src/settings-schema.ts");
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

const icons = new Set(
  [...read("../src/icons.tsx").matchAll(/^  ([a-zA-Z]+): \(\) =>/gm)].map((m) => m[1]),
);
const app = read("../src/App.tsx");

const rows = PAGES.flatMap((page) =>
  page.groups.flatMap((group) => group.rows.map((row) => ({ page, group, row }))),
);
const definedKeys = new Set([
  ...rows.filter(({ row }) => "key" in row).map(({ row }) => row.key),
  ...Object.values(PIPELINE_KEYS),
]);

test("the icon set was read", () => {
  // Guards the guards below: an empty set would fail every icon check for
  // the wrong reason.
  assert.ok(icons.size > 20, `only ${icons.size} icons found in icons.tsx`);
});

test("pages have unique ids and icons that exist", () => {
  const ids = PAGES.map((p) => p.id);
  assert.equal(new Set(ids).size, ids.length, `duplicate page id in ${ids}`);
  for (const page of PAGES) assert.ok(icons.has(page.icon), `page ${page.id} uses missing icon ${page.icon}`);
});

test("every row icon exists", () => {
  for (const { page, row } of rows) {
    if (row.icon) assert.ok(icons.has(row.icon), `${page.id} › ${row.title} uses missing icon ${row.icon}`);
  }
});

test("row titles are unique within a group, since React keys rows by title", () => {
  for (const page of PAGES) {
    for (const group of page.groups) {
      const titles = group.rows.map((r) => r.title);
      assert.equal(new Set(titles).size, titles.length, `duplicate row title in ${page.id} › ${group.label}`);
    }
  }
});

test("every toggle has a key and a boolean default", () => {
  for (const { page, row } of rows.filter(({ row }) => row.kind === "toggle")) {
    assert.ok(row.key, `${page.id} › ${row.title} has no key`);
    assert.equal(typeof row.defaultValue, "boolean", `${page.id} › ${row.title} default is not a boolean`);
  }
});

test("conditions and cascades name keys the schema defines", () => {
  const conditions = [
    ...PAGES.flatMap((p) => p.groups.filter((g) => g.when).map((g) => [`${p.id} › ${g.label}`, g.when.key])),
    ...rows.filter(({ row }) => row.when).map(({ page, row }) => [`${page.id} › ${row.title}`, row.when.key]),
  ];
  for (const [where, key] of conditions) {
    assert.ok(definedKeys.has(key), `${where} depends on ${key}, which no row defines — it can never be true`);
  }
  for (const { page, row } of rows) {
    for (const key of row.cascadeOff ?? []) {
      assert.ok(definedKeys.has(key), `${page.id} › ${row.title} switches off ${key}, which no row defines`);
    }
  }
});

test("nested rows sit under a parent", () => {
  for (const page of PAGES) {
    for (const group of page.groups) {
      group.rows.forEach((row, index) => {
        if (!row.depth) return;
        const above = group.rows.slice(0, index);
        assert.ok(
          above.some((r) => (r.depth ?? 0) === row.depth - 1),
          `${page.id} › ${row.title} is nested at depth ${row.depth} with no parent above it`,
        );
      });
    }
  }
});

test("presets set exactly the pipeline keys", () => {
  const names = Object.keys(PIPELINE_KEYS).sort();
  for (const preset of PIPELINE_PRESETS) {
    for (const name of names) {
      assert.equal(typeof preset[name], "boolean", `preset ${preset.id ?? preset.label} leaves ${name} unset`);
    }
  }
});

test("the permissions section exists once, on the page the launch landing opens", () => {
  const permissions = rows.filter(({ row }) => row.kind === "permissions");
  assert.equal(permissions.length, 1, `expected one permissions section, found ${permissions.length}`);
  const landing = app.match(/function useLandOnMissingPermissions[\s\S]*?setActiveId\("([a-z]+)"\)/);
  assert.ok(landing, "App.tsx no longer lands on a page when permissions are missing");
  assert.equal(permissions[0].page.id, landing[1], "the landing opens a page the permissions section is not on");
});

test("every custom page has a component", () => {
  for (const page of PAGES.filter((p) => p.custom)) {
    assert.match(app, new RegExp(`custom === "${page.custom}"`), `no component renders the ${page.custom} page`);
  }
});
