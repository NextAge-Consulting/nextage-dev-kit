// Regression suite for _claude-project/templates/testing/settings.ts, the layered test
// settings resolver: the kit's default, then test/project.ts, then the developer's .env.
//
// Lives outside every synced source directory, so it never reaches a consumer. Node strips
// the file's types and imports it directly; it has no imports of its own.
//
//   node --test tests/templates/test-settings.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";
import { positiveInteger, resolveSetting } from "../../_claude-project/templates/testing/settings.ts";

const workers = { kind: positiveInteger, kitDefault: 8, projectKey: "integrationWorkers", envKey: "INTEGRATION_WORKERS" };

test("with nothing set, the kit's default", () => {
  assert.equal(resolveSetting(workers, {}, {}), 8);
});

test("a project value wins over the kit's default", () => {
  assert.equal(resolveSetting(workers, { integrationWorkers: 20 }, {}), 20);
});

test(".env wins over the project value", () => {
  assert.equal(resolveSetting(workers, { integrationWorkers: 20 }, { INTEGRATION_WORKERS: "4" }), 4);
});

test(".env wins over the kit's default when the project sets nothing", () => {
  assert.equal(resolveSetting(workers, {}, { INTEGRATION_WORKERS: "12" }), 12);
});

test("another key in .env does not set this one", () => {
  assert.equal(resolveSetting(workers, { integrationWorkers: 20 }, { INTEGRATION_LOCK_TIMEOUT_MS: "4" }), 20);
});

for (const raw of ["abc", "0", "-3", "2.5", "1e3", "08", "", " 4", "99999999999999999999"]) {
  test(`an invalid .env value ${JSON.stringify(raw)} fails, naming the key and .env`, () => {
    assert.throws(
      () => resolveSetting(workers, { integrationWorkers: 20 }, { INTEGRATION_WORKERS: raw }),
      (error) => error instanceof Error && error.message.startsWith("INTEGRATION_WORKERS in .env is ") && error.message.includes("a whole number, 1 or more"),
    );
  });
}

for (const value of [0, -1, 2.5, Number.NaN, "8", null]) {
  test(`an invalid project value ${String(value)} fails, naming the key and test/project.ts`, () => {
    assert.throws(
      () => resolveSetting(workers, { integrationWorkers: value }, {}),
      (error) => error instanceof Error && error.message.startsWith("integrationWorkers in test/project.ts is "),
    );
  });
}

test("a valid .env value is used even when the project value is invalid", () => {
  assert.equal(resolveSetting(workers, { integrationWorkers: 0 }, { INTEGRATION_WORKERS: "6" }), 6);
});
