// SQL Server connection settings for the integration tests — the kit's, kept current by
// /sync-dev-kit (sqlserver-drizzle.md §II, §V).

import sql from "mssql";

// Every string parameter goes to SQL Server as `varchar`, not the driver's default
// `nvarchar`. Drizzle binds parameters with no type, so the driver infers one, and an
// `nvarchar` value compared with a `varchar` column makes SQL Server convert the column
// on every row: an index seek becomes a scan. The app registers the same mapping where it
// builds its database handles (sqlserver-drizzle.md §II); this keeps the tests' handles
// binding the way the app's do.
sql.map.register(String, sql.VarChar);

/** A keyword value in braces, `}` doubled, so a `;`, `=`, brace, quote or edge space in it survives. */
function braced(value: string): string {
  return `{${value.replaceAll("}", "}}")}}`;
}

/**
 * The connection string for the database `env`'s `DB_*` keys name, in the ADO keyword
 * form — the only one the `mssql` driver accepts (sqlserver-drizzle.md §II). `env` is the
 * sandbox the integration setup read `.env` into, never `process.env`.
 */
export function connectionStringFromEnv(env: Record<string, string | undefined>): string {
  const { DB_SERVER: server, DB_DATABASE: database, DB_USER: user, DB_PASSWORD: password } = env;
  if (!server || !database || !user || !password) {
    throw new Error("DB_SERVER, DB_DATABASE, DB_USER and DB_PASSWORD must all be set in .env");
  }
  return (
    `Server=${braced(`${server},${env.DB_PORT ?? "1433"}`)};Database=${braced(database)};` +
    `User Id=${braced(user)};Password=${braced(password)};` +
    `Encrypt=${env.DB_ENCRYPT ?? "true"};TrustServerCertificate=${env.DB_TRUST_SERVER_CERTIFICATE ?? "true"}`
  );
}

/**
 * The integration tests' pool settings, from the connection string above. The pool lends a
 * connection unchecked: by default `mssql` runs `SELECT 1` on each one before lending it,
 * a server round trip on every test. A connection the pool already knows is closed or
 * errored is still discarded, and one that died unnoticed fails the test at its
 * transaction's first statement, which reports it.
 */
export function testPoolConfig(connectionString: string): sql.config & { validateConnection: boolean } {
  // `validateConnection` is an `mssql` setting its type definitions do not list.
  return { ...sql.ConnectionPool.parseConnectionString(connectionString), validateConnection: false };
}
