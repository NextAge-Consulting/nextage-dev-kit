import { test } from 'node:test'
import assert from 'node:assert/strict'
import { REF_AS_PROP } from './ref-as-prop.mjs'

const { isPlainComponent } = new Function(`${REF_AS_PROP}; return { isPlainComponent }`)()

test('a plain function component is wrapped', () => {
  assert.equal(isPlainComponent(function Button() {}), true)
})

test('a React Aria collection element is left as the function itself', () => {
  function Item() {}
  Item.getCollectionNode = function* () {}
  assert.equal(isPlainComponent(Item), false)
})

test('a class component and an exotic component are not plain', () => {
  class Legacy {}
  Legacy.prototype.isReactComponent = {}
  assert.equal(isPlainComponent(Legacy), false)
  const memo = Object.assign(() => null, { $$typeof: Symbol.for('react.memo') })
  assert.equal(isPlainComponent(memo), false)
})
