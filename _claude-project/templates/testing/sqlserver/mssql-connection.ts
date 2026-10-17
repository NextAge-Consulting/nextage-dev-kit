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
