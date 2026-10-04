// This project's test settings. The kit's test files read them; this file is the
// project's, and /sync-dev-kit seeds it once and never offers it again.
//
// Every setting is described in ./define.ts. Helpers of the project's own — domain
// fakes, a second database's test function — go in files of their own beside this one.

import * as schema from "../src/db/schema";
import { defineTestProject } from "./define";

export default defineTestProject({
  timezone: "America/Chicago",
  schema,
});
