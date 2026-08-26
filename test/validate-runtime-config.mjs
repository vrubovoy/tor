import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'

if (process.argv.length < 4) {
  console.error('Usage: node validate-runtime-config.mjs CONFIG_JS EXPECTED_JSON')
  process.exit(2)
}

const source = await readFile(process.argv[2], 'utf8')
const expected = JSON.parse(process.argv[3])
const window = {}
vm.runInNewContext(source, { window }, { timeout: 1000 })
const config = JSON.parse(JSON.stringify(window.__HOF_CONFIG__))

assert.equal(config?.schemaVersion, 1)
for (const [key, value] of Object.entries(expected)) {
  assert.deepEqual(config?.[key], value, `${key} differs`)
}
