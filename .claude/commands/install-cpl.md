# Install CPL

Install or update CPL (Claude Project Launcher) from the starter kit repo.

This command should only be run from within the starter kit repo itself.

## Step 1: Verify we're in the starter kit

Check for `_cpl/sync-cpl.sh` in the current directory. If it doesn't exist, tell the user this command must be run from the starter kit repo.

## Step 2: Run the install script

```bash
"$PWD/_cpl/sync-cpl.sh" --force
```

## Step 3: Report the results

After running, report what happened:
- Was it a fresh install or an update?
- What version was installed?
- Were there any compilation errors?

If there were errors, investigate and suggest fixes.
