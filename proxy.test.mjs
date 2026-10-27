// 代理的纯逻辑单元测试（不启动真服务器，快速回归）。
// 运行：node proxy.test.mjs
import assert from 'node:assert/strict'
import {
  parseArgv,
  fixObjectSchemas,
  fixToolInputSchema,
  fixToolsListResult,
  isToolsListResult,
} from './mcp-schema-fix-proxy.mjs'

let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed += 1
    console.log(`  PASS  ${name}`)
  } catch (error) {
    failures.push({ name, message: error?.message ?? String(error) })
    console.log(`  FAIL  ${name}`)
    console.log(`        → ${error?.message ?? error}`)
  }
}

console.log('parseArgv')
check('-- 分隔：识别命令与参数', () => {
  const r = parseArgv(['--', 'exe.exe', '--flag=1', 'x'])
  assert.equal(r.command, 'exe.exe')
  assert.deepEqual(r.args, ['--flag=1', 'x'])
  assert.equal(r.probe, false)
})
check('--probe 在 -- 之前被识别', () => {
  const r = parseArgv(['--probe', '--', 'exe.exe'])
  assert.equal(r.probe, true)
  assert.equal(r.command, 'exe.exe')
})
check('没有 -- 时 command 为 undefined（不猜）', () => {
  const r = parseArgv(['exe.exe', 'a'])
  assert.equal(r.command, undefined)
  assert.deepEqual(r.args, [])
})
check('-- 之后的 --probe 不会被当成代理开关', () => {
  const r = parseArgv(['--', 'exe.exe', '--probe'])
  assert.equal(r.probe, false)
  assert.deepEqual(r.args, ['--probe'])
})

console.log('\nfixObjectSchemas')
check('病根形状：object 缺 properties → 补空对象', () => {
  const s = { type: 'object', additionalProperties: false }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties, {})
  assert.equal(changed.length, 1)
})
check('已有 properties 的 schema 不动（幂等）', () => {
  const s = { type: 'object', properties: { a: { type: 'string' } } }
  const before = JSON.stringify(s)
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.equal(JSON.stringify(s), before)
  assert.equal(changed.length, 0)
})
check('properties 为 null → 补空对象', () => {
  const s = { type: 'object', properties: null }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties, {})
})
check('type 为数组含 object 时也要修', () => {
  const s = { type: ['object', 'null'], additionalProperties: false }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties, {})
})
check('type 不是 object 时不碰（字符串 schema）', () => {
  const s = { type: 'string' }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.equal('properties' in s, false)
  assert.equal(changed.length, 0)
})
check('嵌套 properties 里的子 schema 也要修', () => {
  const s = { type: 'object', properties: { inner: { type: 'object', additionalProperties: false } } }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties.inner.properties, {})
  assert.equal(changed.length, 1)
})
check('oneOf/anyOf 分支里的子 schema 也要修', () => {
  const s = { type: 'object', properties: { at: { oneOf: [{ type: 'string' }, { type: 'object', additionalProperties: false }] } } }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties.at.oneOf[1].properties, {})
})
check('items 里的子 schema 也要修', () => {
  const s = { type: 'object', properties: { list: { type: 'array', items: { type: 'object', additionalProperties: false } } } }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.properties.list.items.properties, {})
})
check('$defs 里的子 schema 也要修', () => {
  const s = { type: 'object', properties: {}, $defs: { X: { type: 'object', additionalProperties: false } } }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.deepEqual(s.$defs.X.properties, {})
})
check('additionalProperties 为布尔时不误当 schema 递归', () => {
  const s = { type: 'object', properties: {}, additionalProperties: false }
  const changed = []
  fixObjectSchemas(s, 'tool', changed, [])
  assert.equal(changed.length, 0)
})
check('required 含未声明属性 → 记 warning 但不自动改（不放宽约束）', () => {
  const s = { type: 'object', properties: { a: { type: 'string' } }, required: ['a', 'ghost'] }
  const changed = []
  const warnings = []
  fixObjectSchemas(s, 'tool', changed, warnings)
  assert.deepEqual(s.required, ['a', 'ghost'])
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /ghost/)
})

console.log('\nfixToolInputSchema')
check('inputSchema 缺失 → 补完整空 schema', () => {
  const tool = { name: 'x' }
  const changed = []
  fixToolInputSchema(tool, changed, [])
  assert.deepEqual(tool.inputSchema, { type: 'object', properties: {} })
})
check('inputSchema 为 null → 补完整空 schema', () => {
  const tool = { name: 'x', inputSchema: null }
  const changed = []
  fixToolInputSchema(tool, changed, [])
  assert.deepEqual(tool.inputSchema, { type: 'object', properties: {} })
})
check('inputSchema 是数组 → 替换为等价空对象 schema', () => {
  const tool = { name: 'x', inputSchema: [] }
  const changed = []
  fixToolInputSchema(tool, changed, [])
  assert.deepEqual(tool.inputSchema, { type: 'object', properties: {} })
})
check('缺 type 但已有 properties → 补 object', () => {
  const tool = { name: 'x', inputSchema: { properties: { a: { type: 'string' } } } }
  const changed = []
  fixToolInputSchema(tool, changed, [])
  assert.equal(tool.inputSchema.type, 'object')
  assert.deepEqual(tool.inputSchema.properties, { a: { type: 'string' } })
})
check('正常 schema 完全不动', () => {
  const tool = { name: 'x', inputSchema: { type: 'object', properties: { p: { type: 'string' } }, required: ['p'] } }
  const before = JSON.stringify(tool)
  const changed = []
  fixToolInputSchema(tool, changed, [])
  assert.equal(JSON.stringify(tool), before)
  assert.equal(changed.length, 0)
})

console.log('\nfixToolsListResult / isToolsListResult')
check('isToolsListResult 认 tools/list 成功响应', () => {
  assert.equal(isToolsListResult({ jsonrpc: '2.0', id: 2, result: { tools: [] } }), true)
})
check('isToolsListResult 不认错误响应', () => {
  assert.equal(isToolsListResult({ jsonrpc: '2.0', id: 2, error: { code: -32601 } }), false)
})
check('isToolsListResult 不认 result 无 tools 的响应', () => {
  assert.equal(isToolsListResult({ jsonrpc: '2.0', id: 2, result: { resources: [] } }), false)
})
check('isToolsListResult 不认通知', () => {
  assert.equal(isToolsListResult({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' }), false)
})
check('整表修复：只动坏的那个，好的保持逐字节不变', () => {
  const good = { name: 'good', inputSchema: { type: 'object', properties: { a: { type: 'string' } } } }
  const goodBefore = JSON.stringify(good)
  const result = { tools: [good, { name: 'bad', inputSchema: { type: 'object', additionalProperties: false } }] }
  const { changed } = fixToolsListResult(result)
  assert.equal(JSON.stringify(good), goodBefore)
  assert.deepEqual(result.tools[1].inputSchema.properties, {})
  assert.equal(changed.length, 1)
})
check('幂等：连修两次，第二次零改动', () => {
  const result = { tools: [{ name: 'bad', inputSchema: { type: 'object', additionalProperties: false } }] }
  fixToolsListResult(result)
  const second = fixToolsListResult(result)
  assert.equal(second.changed.length, 0)
})

console.log(`\n${passed}/${passed + failures.length} 通过。`)
if (failures.length > 0) {
  for (const f of failures) console.log(`  - ${f.name}: ${f.message}`)
  process.exit(1)
}
