// The SQL Server connection-string builder's own test — the kit's, kept current by
// /sync-dev-kit. The driver's parser reads the string back, so a value that would split
// or truncate the string fails here rather than as a refused login.

import sql from "mssql";
import { describe, expect, it } from "vitest";
import { connectionStringFromEnv } from "./mssql-connection";

const base = { DB_SERVER: "db.example.com", DB_DATABASE: "appdb", DB_USER: "app_user", DB_PASSWORD: "secret" };

describe("connectionStringFromEnv", () => {
  it("reads back every key it was given", () => {
    const config = sql.ConnectionPool.parseConnectionString(connectionStringFromEnv({ ...base, DB_PORT: "14330" }));
    expect(config).toMatchObject({ server: "db.example.com", port: 14330, database: "appdb", user: "app_user", password: "secret" });
  });

  it.each(["a;b", "x=y", "br{ce}s", "}}", 'q"uote', "it's", " edge "])("keeps the value %j whole", (value) => {
    const config = sql.ConnectionPool.parseConnectionString(
      connectionStringFromEnv({ ...base, DB_DATABASE: value, DB_USER: value, DB_PASSWORD: value }),
    );
    expect(config).toMatchObject({ database: value, user: value, password: value });
  });

  it("refuses when a required key is missing", () => {
    expect(() => connectionStringFromEnv({ ...base, DB_PASSWORD: undefined })).toThrow(/DB_PASSWORD/);
  });
});
