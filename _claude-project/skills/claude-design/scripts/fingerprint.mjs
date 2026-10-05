/**
 * fingerprint.mjs — whether a build would publish anything new.
 *
 * A build writes the system to <out>/project/ and stamps it with its release, the day
 * and the commit. The fingerprint hashes every file there by path and content with
 * those three taken out, so two builds of the same code agree whatever their release
 * number or day, and differ when anything a design would receive differs. The build
 * appends it to the release note (`· content <hash>`), where the next publish reads it.
 */
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const TEXT = /\.(md|html|json|css|js|ts|txt|svg)$/

function filesUnder(dir, prefix = '') {
  const out = []
  for (const entry of fs.readdirSync(path.join(dir, prefix), { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) out.push(...filesUnder(dir, rel))
    else out.push(rel)
  }
  return out
}

/** The fingerprint of <projectDir>, with each of `volatile` (the stamp, the commit, the
 * day) removed from every text file first. */
export function contentFingerprint(projectDir, volatile) {
  const drop = volatile.filter(Boolean).sort((a, b) => b.length - a.length)
  const hash = createHash('sha256')
  for (const rel of filesUnder(projectDir).sort()) {
    let bytes = fs.readFileSync(path.join(projectDir, rel))
    if (TEXT.test(rel)) {
      let text = bytes.toString('utf8')
      for (const v of drop) text = text.replaceAll(v, '\u0000')
      bytes = Buffer.from(text, 'utf8')
    }
    hash.update(`${rel}\0${bytes.length}\0`).update(bytes)
  }
  return hash.digest('hex').slice(0, 12)
}

/** The fingerprint a release note carries, or null for a note written before there was one. */
export const noteFingerprint = (note) => (typeof note === 'string' ? (note.match(/· content ([0-9a-f]{12})\b/)?.[1] ?? null) : null)
