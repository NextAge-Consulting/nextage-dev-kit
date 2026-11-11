import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { anchorLine, ask, askOnce, fixturesFor, judgeCandidates, mergeLedger, parseQuestions, placeFingerprint, readLedger, readQuestions, renderCandidate, systemPrompt } from './judge.mjs'

/** A stub CLI standing in for claude: answers from STUB_ANSWERS, one JSON per line, in order. */
function stub(answers) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'judge-'))
  const bin = path.join(dir, 'claude')
  const log = path.join(dir, 'calls')
  fs.writeFileSync(
    bin,
    `#!/bin/bash
cat >> "${log}.input"
until mkdir "${log}.lock" 2>/dev/null; do sleep 0.01; done
n=$(cat "${log}" 2>/dev/null | wc -l | tr -d ' ')
echo call >> "${log}"
rmdir "${log}.lock"
sed -n "$((n + 1))p" "${dir}/answers"
`,
  )
  fs.chmodSync(bin, 0o755)
  fs.writeFileSync(path.join(dir, 'answers'), `${answers.join('\n')}\n`)
  return { bin, calls: () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').length : 0), input: () => fs.readFileSync(`${log}.input`, 'utf8') }
}
const answer = (a, ...quotes) => JSON.stringify({ is_error: false, total_cost_usd: 0.01, structured_output: { answer: a, quotes } })

test('the shipped questions parse, every field present, and every question has cases of both answers', () => {
  const qs = readQuestions()
  assert.ok(qs.length >= 5)
  for (const q of qs) {
    assert.ok(q.given.length, `${q.name}: no Given fields`)
    const cases = fixturesFor(q.name)
    assert.ok(cases.some((c) => c.answer === 'yes'), `${q.name}: no yes case`)
    assert.ok(cases.some((c) => c.answer === 'no'), `${q.name}: no no case`)
    for (const c of cases) assert.doesNotThrow(() => renderCandidate(q, c.candidate), `${q.name}/${c.name}: a Given field is missing`)
  }
})

test('a question is its heading and its bold fields; prose outside a question is ignored', () => {
  const qs = parseQuestions(
    [
      '# Judge questions', 'intro', '## What is not a question', '- stuff', '---',
      '## ONE — the first', '', '**Asked about:** a thing.', '**Given:** `a`, `b.c`.', '**Quote:** the thing.',
      '**Yes when:** it is', 'so.', '**No when:** it is not.', '**Example yes:** x → yes.', '**Example no:** y → no.', '---',
    ].join('\n'),
  )
  assert.equal(qs.length, 1)
  assert.equal(qs[0].name, 'ONE')
  assert.deepEqual(qs[0].given, ['a', 'b.c'])
  assert.equal(qs[0].fields['Yes when'], 'it is so.')
})

test('a question missing a field fails by name', () => {
  assert.throws(() => parseQuestions('## ONE — t\n**Asked about:** a.\n**Given:** `a`.\n'), /ONE: missing Quote/)
})

const Q = parseQuestions('## QQ — t\n**Asked about:** a.\n**Given:** `name`, `pair.left` (its text, with `other` words).\n**Quote:** the name.\n**Yes when:** y.\n**No when:** n.\n**Example yes:** a.\n**Example no:** b.\n')[0]
const C = { name: 'thing-one', pair: { left: 'left text' }, extra: 'never sent' }

test('the candidate is rendered as its Given fields only, and the system prompt carries the question', () => {
  const text = renderCandidate(Q, C)
  assert.match(text, /=== name ===\nthing-one/)
  assert.match(text, /=== pair\.left ===\nleft text/)
  assert.doesNotMatch(text, /never sent/)
  assert.deepEqual(Q.given, ['name', 'pair.left'])
  assert.match(systemPrompt(Q), /Question: QQ — t/)
  assert.match(systemPrompt(Q), /Yes when: y/)
})

test('one answer is read; every quote must be in the candidate, each on its own', async () => {
  const ok = stub([answer('yes', 'thing-one', 'left text')])
  assert.deepEqual(await askOnce(Q, C, { bin: ok.bin }), { answer: 'yes', quote: 'thing-one | left text', quotes: ['thing-one', 'left text'], cost: 0.01 })
  assert.match(ok.input(), /=== name ===/)
  const bad = stub([answer('yes', 'thing-one', 'invented text')])
  assert.match((await askOnce(Q, C, { bin: bad.bin })).error, /quote not in candidate: invented text/)
  // A list field is shown as JSON: an item copied with the quotes it was shown in is a quote.
  const LQ = parseQuestions('## LQ — t\n**Asked about:** a.\n**Given:** `name`, `accepts`.\n**Quote:** the class.\n**Yes when:** y.\n**No when:** n.\n**Example yes:** a.\n**Example no:** b.\n')[0]
  const listed = stub([answer('no', '"gap-*"'), answer('no', 'gap-*')])
  assert.equal((await askOnce(LQ, { name: 'x', accepts: ['gap-*'] }, { bin: listed.bin })).answer, 'no')
  assert.equal((await askOnce(LQ, { name: 'x', accepts: ['gap-*'] }, { bin: listed.bin })).answer, 'no')
  const none = stub([JSON.stringify({ is_error: false, structured_output: { answer: 'yes', quotes: [] } })])
  assert.equal((await askOnce(Q, C, { bin: none.bin })).error, 'no quote')
})

test('three answers decide by majority; a discarded answer is a vote for neither', async () => {
  const two = stub([answer('yes', 'thing-one'), answer('no', 'left text'), answer('yes', 'thing-one')])
  const r = await ask(Q, C, { runs: 3, bin: two.bin })
  assert.equal(r.answer, 'yes')
  assert.deepEqual(r.votes, { yes: 2, no: 1, none: 0 })
  assert.equal(two.calls(), 3)
  const split = stub([answer('yes', 'thing-one'), answer('no', 'left text'), answer('yes', 'nowhere')])
  const s = await ask(Q, C, { runs: 3, bin: split.bin })
  assert.equal(s.answer, 'none')
  assert.deepEqual(s.votes, { yes: 1, no: 1, none: 1 })
})

test('a CLI that fails or returns nothing readable is no answer, never a no', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'judge-'))
  const bin = path.join(dir, 'claude')
  fs.writeFileSync(bin, '#!/bin/bash\necho boom >&2\nexit 3\n')
  fs.chmodSync(bin, 0o755)
  assert.match((await askOnce(Q, C, { bin })).error, /exited 3/)
  const junk = stub(['not json'])
  assert.equal((await askOnce(Q, C, { bin: junk.bin })).error, 'unparseable output')
})

test('candidates: a finding is a yes without asking; a question is asked; a yes and a no are told apart', async () => {
  const s = stub([answer('yes', 'thing-one'), answer('yes', 'thing-one'), answer('no', 'left text')])
  const text = [
    JSON.stringify({ finding: 'SECOND-BLOCK', at: 'src/a.tsx:1', text: 'a second block' }),
    JSON.stringify({ question: 'QQ', at: 'src/b.tsx:4', candidate: C }),
    'not json',
    JSON.stringify({ question: 'NOPE', at: 'src/c.tsx:1', candidate: C }),
  ].join('\n')
  const r = await judgeCandidates([Q], text, { runs: 3, bin: s.bin })
  assert.deepEqual(r.yes.map((y) => [y.question, y.at]), [['SECOND-BLOCK', 'src/a.tsx:1'], ['QQ', 'src/b.tsx:4']])
  assert.deepEqual(r.no, [])
  assert.equal(r.asked, 1)
  assert.equal(r.errors.length, 2)
})

test('the ledger: a yes becomes a pending item with its line\'s fingerprint; a changed, excepted or re-judged-no line drops it', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-'))
  fs.mkdirSync(path.join(repo, 'src'))
  fs.writeFileSync(path.join(repo, 'src/a.tsx'), 'one\n<Card className="p-2">\nthree {/* design-accepted — fine */}\n')
  const fp = placeFingerprint(repo, 'src/a.tsx:2')
  assert.equal(fp.excepted, false)
  assert.equal(placeFingerprint(repo, 'src/a.tsx:3').excepted, true)
  assert.equal(placeFingerprint(repo, 'src/a.tsx:9'), null)
  assert.equal(placeFingerprint(repo, 'src/none.tsx:1'), null)

  const yes = [{ question: 'REPAINT', at: 'src/a.tsx:2', quote: 'p-2' }, { question: 'REPAINT', at: 'src/a.tsx:3', quote: 'three' }]
  const ledger = mergeLedger(repo, [], { yes })
  assert.deepEqual(ledger.map((i) => [i.question, i.at, i.fingerprint]), [['REPAINT', 'src/a.tsx:2', fp.fingerprint]], 'the excepted line is never recorded')

  // Unchanged: kept, a later no notwithstanding — only the human's word or a code change settles it. Line changed: dropped.
  assert.equal(mergeLedger(repo, ledger, {}).length, 1)
  assert.equal(mergeLedger(repo, ledger, { no: [{ question: 'REPAINT', at: 'src/a.tsx:2' }] }).length, 1, 'a re-asked no removes nothing')
  fs.writeFileSync(path.join(repo, 'src/a.tsx'), 'one\n<Card className="p-4">\nthree\n')
  assert.equal(mergeLedger(repo, ledger, {}).length, 0)
  assert.deepEqual(readLedger(path.join(repo, 'none.json')), [])
})

test('an anchored yes rests on a changed line: the item is placed on the line a quote names, and a yes about any other line is not kept', async () => {
  const SQ = parseQuestions('## SQ — t\n**Asked about:** a.\n**Given:** `rule`, `screen`.\n**Quote:** the line.\n**Yes when:** y.\n**No when:** n.\n**Example yes:** a.\n**Example no:** b.\n')[0]
  const screen = '<Alert variant="destructive">\n  <Button type="submit">\n      onSubmit={() => submitOnce(form)}\n</Alert>'
  const line = (at, about) => JSON.stringify({ question: 'SQ', at, about, anchor: { file: 'src/s.tsx', lines: [[7, '      onSubmit={() => submitOnce(form)}'], [8, '    )']] }, candidate: { rule: 'Saving is busy.', screen } })
  // Three answers each: the first candidate's yeses quote the changed line, the second's an untouched one.
  const s = stub([
    answer('yes', 'onSubmit={() => submitOnce(form)}'), answer('yes', 'Saving is busy.', 'onSubmit={() => submitOnce(form)}'), answer('no', '<Button type="submit">'),
    answer('yes', '<Alert variant="destructive">'), answer('yes', '<Alert variant="destructive">'), answer('yes', '<Button type="submit">'),
  ])
  const r = await judgeCandidates([SQ], [line('src/s.tsx:7', 'saving.md'), line('src/s.tsx:7', 'alerts.md')].join('\n'), { runs: 3, bin: s.bin, })
  assert.equal(r.asked, 2)
  const kept = r.yes.concat(r.unchanged).map((y) => y.about).sort()
  assert.deepEqual(kept, ['alerts.md', 'saving.md'])
  assert.equal(r.yes.length + r.unchanged.length, 2)
  for (const y of r.yes) assert.equal(y.at, 'src/s.tsx:7', 'placed on the changed line its quote names')
  for (const u of r.unchanged) assert.match(u.quote, /Alert|Button/, 'a yes quoting only untouched lines is not kept')

  assert.equal(anchorLine({ lines: [[7, '      onSubmit={() => submitOnce(form)}']] }, ['onSubmit={() =>   submitOnce(form)}']), 7, 'whitespace is folded')
  assert.equal(anchorLine({ lines: [[3, '  <Button type="submit">'], [4, '    Save']] }, ['<Button type="submit">\n    Save\n</Button>']), 3, 'a quote spanning lines rests on the first changed line it holds')
  assert.equal(anchorLine({ lines: [[9, '    )'], [10, '}']] }, [')', '}']), null, 'a line of punctuation alone is never the evidence')
  assert.equal(anchorLine({ lines: [[7, 'onSubmit={() => submitOnce(form)}']] }, ['<Alert variant="destructive">']), null)
})

test('the ledger: two rules departing on one line are two items; a marker on a comment-only line above answers for the line beneath', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-'))
  fs.mkdirSync(path.join(repo, 'src'))
  fs.writeFileSync(path.join(repo, 'src/a.tsx'), 'one\n{/* design-accepted — the kiosk has no banner */}\n<Card className="p-2">\nfour // design-accepted — fine\n<Row />\n')
  assert.equal(placeFingerprint(repo, 'src/a.tsx:3').excepted, true, 'the comment line above answers')
  assert.equal(placeFingerprint(repo, 'src/a.tsx:5').excepted, false, 'a marker trailing the code line above answers for that line alone')
  const yes = [
    { question: 'FOLLOWS-RULE', at: 'src/a.tsx:5', about: 'saving.md', quote: '<Row />' },
    { question: 'FOLLOWS-RULE', at: 'src/a.tsx:5', about: 'loading.md', quote: '<Row />' },
    { question: 'FOLLOWS-RULE', at: 'src/a.tsx:3', about: 'saving.md', quote: '<Card className="p-2">' },
  ]
  const ledger = mergeLedger(repo, [], { yes })
  assert.deepEqual(ledger.map((i) => [i.at, i.about]), [['src/a.tsx:5', 'loading.md'], ['src/a.tsx:5', 'saving.md']])
  assert.equal(mergeLedger(repo, ledger, { yes }).length, 2, 'asked again, the same two')
})
