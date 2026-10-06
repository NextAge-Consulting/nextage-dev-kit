import { test } from 'node:test'
import assert from 'node:assert/strict'
import { atomModule, parseBlockTypes, readBlockTypes } from './block-types.mjs'

test('the shipped list parses: every type named, each frame atom with the types that wrap it', () => {
  const { names, frames } = readBlockTypes()
  for (const t of ['ModalShell', 'ReviewDialog', 'BrowseScreen', 'SaveStatus']) assert.ok(names.has(t), t)
  assert.deepEqual(frames.get('AlertDialog'), ['ConfirmDialog'])
  assert.ok(frames.get('Dialog').includes('ReviewDialog'))
  assert.ok(frames.get('Sheet').includes('EditDrawer'))
  assert.ok(!frames.has(''))
})

test('only tables headed Type count, and a blank Wraps names no atom', () => {
  const { names, frames } = parseBlockTypes(
    ['| Type | Wraps |', '|---|---|', '| A | Dialog |', '| B | |', '', '| Other | x |', '|---|---|', '| C | y |'].join('\n'),
  )
  assert.deepEqual([...names], ['A', 'B'])
  assert.deepEqual([...frames], [['Dialog', ['A']]])
})

test('an atom maps to its module the way shadcn names it', () => {
  assert.equal(atomModule('AlertDialog'), 'alert-dialog')
  assert.equal(atomModule('Sheet'), 'sheet')
})
