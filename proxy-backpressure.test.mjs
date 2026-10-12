// 专测背压丢帧（我刚修掉的 P0）：用 OutputPump 模拟 stdout 缓冲区满，
// 验证「一次进来多帧」时一帧都不丢。
import { OutputPump, transformServerFrame, LineFramer } from './mcp-schema-fix-proxy.mjs'

let passed = 0
const failures = []
function check(name, fn) {
  try { fn(); passed += 1; console.log(`  PASS  ${name}`) }
  catch (e) { failures.push(name); console.log(`  FAIL  ${name}\n        → ${e?.message ?? e}`) }
}

console.log('OutputPump —— 背压下的丢帧回归（初版 P0）')

check('写出口永不背压：全部按序送达', () => {
  const written = []
  const pump = new OutputPump((c) => { written.push(c.toString()); return true })
  pump.push([Buffer.from('A\n'), Buffer.from('B\n'), Buffer.from('C\n')])
  if (written.join('') !== 'A\nB\nC\n') throw new Error(`实际 ${JSON.stringify(written.join(''))}`)
  if (pump.pending !== 0) throw new Error('队列未排空')
})

check('第 2 帧遇背压：该帧已写出（不重写），后续帧留在队列', () => {
  const written = []
  const pump = new OutputPump((c) => {
    written.push(c.toString())
    return written.length < 2 // 第 1 帧接受；第 2 帧写出但报告「缓冲区满」
  })
  pump.push([Buffer.from('A\n'), Buffer.from('B\n'), Buffer.from('C\n')])
  // Node 语义：write 返回 false = 该帧已被接受但请暂停 ⇒ 写出 2 帧、剩 1 帧排队
  if (written.join('') !== 'A\nB\n') throw new Error(`已写出应为 A\\nB\\n，实际 ${JSON.stringify(written.join(''))}`)
  if (pump.pending !== 1) throw new Error(`队列应剩 1 帧，实际 ${pump.pending}`)
  if (!pump.stalled) throw new Error('应为 stalled 状态')
  pump.pump(true) // 模拟 drain
  if (written.join('') !== 'A\nB\nC\n') throw new Error(`补写后不完整：${JSON.stringify(written.join(''))}`)
  if (pump.pending !== 0) throw new Error('补写后队列未排空')
})

check('全帧遇背压 + 反复 drain：一帧都不许丢、也不许重复', () => {
  const written = []
  let budget = 1 // 每轮 drain 只接受 1 帧
  const pump = new OutputPump((c) => {
    written.push(c.toString())
    budget -= 1
    return budget > 0
  })
  const frames = Array.from({ length: 50 }, (_v, i) => Buffer.from(`frame-${i}\n`))
  pump.push(frames)
  if (written.length !== 1) throw new Error(`应只写出 1 帧，实际 ${written.length}`)
  if (pump.pending !== 49) throw new Error(`应剩 49 帧，实际 ${pump.pending}`)
  // 模拟多次 drain：每次给 1 帧预算，直到排空
  let guard = 0
  while (pump.pending > 0 && guard < 200) {
    budget = 1
    pump.pump(true)
    guard += 1
  }
  if (pump.pending !== 0) throw new Error(`drain 循环后仍未排空（剩 ${pump.pending}）`)
  const all = written.join('')
  for (let i = 0; i < 50; i++) {
    if (!all.includes(`frame-${i}\n`)) throw new Error(`丢了 frame-${i}`)
  }
  // 顺序与不重复
  if (all !== frames.map((f) => f.toString()).join('')) throw new Error('顺序错或出现重复')
})

check('多次 push 交错背压：顺序仍然严格正确', () => {
  const written = []
  let budget = 1
  const pump = new OutputPump((c) => { written.push(c.toString()); budget -= 1; return budget > 0 })
  pump.push([Buffer.from('1\n'), Buffer.from('2\n')])   // 第1帧写出，第2帧排队
  pump.push([Buffer.from('3\n')])                        // 应入队而不是丢掉
  if (pump.pending !== 2) throw new Error(`应剩 2 帧，实际 ${pump.pending}`)
  budget = 99
  pump.pump(true)
  if (written.join('') !== '1\n2\n3\n') throw new Error(`顺序错：${JSON.stringify(written.join(''))}`)
})

check('drain 之前重复 pump 不会重复写出', () => {
  const written = []
  const pump = new OutputPump((c) => { written.push(c.toString()); return false })
  pump.push([Buffer.from('A\n'), Buffer.from('B\n')])
  pump.pump()  // 仍 stalled，应无动作
  pump.pump()
  if (written.length !== 1) throw new Error(`重复 pump 造成了重复写：${JSON.stringify(written)}`)
  pump.pump(true)
  if (written.join('') !== 'A\nB\n') throw new Error(`最终内容错：${JSON.stringify(written.join(''))}`)
})

check('drainNow 排空队列（进程收尾用）', () => {
  const written = []
  const pump = new OutputPump((c) => { written.push(c.toString()); return false })
  pump.push([Buffer.from('X\n'), Buffer.from('Y\n'), Buffer.from('Z\n')])
  pump.drainNow()
  if (pump.pending !== 0) throw new Error('drainNow 后队列未排空')
  if (written.join('') !== 'X\nY\nZ\n') throw new Error(`drainNow 内容错：${JSON.stringify(written.join(''))}`)
})

check('write 抛异常时 drainNow 不炸且清空队列', () => {
  const pump = new OutputPump(() => { throw new Error('EPIPE') })
  pump.push([Buffer.from('A\n')])
  pump.drainNow()
  if (pump.pending !== 0) throw new Error('抛异常后队列未清空')
})

console.log('\ntransformServerFrame —— 帧变换')
check('坏 schema 帧被修好且带换行结尾', () => {
  const msg = { jsonrpc: '2.0', id: 2, result: { tools: [{ name: 't', inputSchema: { type: 'object', additionalProperties: false } }] } }
  const out = transformServerFrame(Buffer.from(`${JSON.stringify(msg)}\n`)).toString()
  if (!out.endsWith('\n')) throw new Error('缺少换行结尾')
  const parsed = JSON.parse(out)
  const p = parsed.result.tools[0].inputSchema.properties
  if (typeof p !== 'object' || p === null || Array.isArray(p)) throw new Error(`properties 未修好：${JSON.stringify(p)}`)
})
check('非 tools/list 帧逐字节原样返回', () => {
  const raw = Buffer.from('{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n')
  const out = transformServerFrame(raw)
  if (!out.equals(raw)) throw new Error('非 tools/list 帧被改动了')
})
check('通知帧原样返回', () => {
  const raw = Buffer.from('{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n')
  if (!transformServerFrame(raw).equals(raw)) throw new Error('通知帧被改动')
})
check('CRLF 帧：能解析、能修复（\r 被 trim 掉）', () => {
  const msg = { jsonrpc: '2.0', id: 2, result: { tools: [{ name: 't', inputSchema: { type: 'object', additionalProperties: false } }] } }
  const raw = Buffer.from(`${JSON.stringify(msg)}\r\n`)
  const out = transformServerFrame(raw).toString()
  // CRLF 输入若未被正确 trim，JSON.parse 会因尾部 \r 失败 → 帧原样返回（含旧 schema）
  const parsed = JSON.parse(out)
  const p = parsed.result.tools[0].inputSchema.properties
  if (typeof p !== 'object' || p === null) throw new Error('CRLF 帧未被修复（trim 失效）')
})
check('无法解析的 JSON 帧原样返回（绝不吞）', () => {
  const raw = Buffer.from('{ this is not json }\n')
  if (!transformServerFrame(raw).equals(raw)) throw new Error('坏帧被改动了')
})
check('空行原样返回', () => {
  const raw = Buffer.from('\n')
  if (!transformServerFrame(raw).equals(raw)) throw new Error('空行被改动')
})

console.log('\nLineFramer —— 分帧')
check('一次大块含多帧时按顺序切出', () => {
  const f = new LineFramer()
  const frames = f.push(Buffer.from('{"a":1}\n{"b":2}\n{"c":3}\n'))
  if (frames.length !== 3) throw new Error(`应 3 帧，实际 ${frames.length}`)
  if (frames.map((x) => x.toString()).join('') !== '{"a":1}\n{"b":2}\n{"c":3}\n') throw new Error('内容不符')
})
check('跨 chunk 的半帧会被拼起来（不丢字节）', () => {
  const f = new LineFramer()
  const first = f.push(Buffer.from('{"hel'))
  if (first.length !== 0) throw new Error('半帧不应产出')
  const second = f.push(Buffer.from('lo":1}\n'))
  if (second.length !== 1) throw new Error(`应产出 1 帧，实际 ${second.length}`)
  if (second[0].toString() !== '{"hello":1}\n') throw new Error(`拼帧错：${second[0].toString()}`)
})
check('CRLF 分帧：\r 保留在帧内（由 transform 的 trim 负责）', () => {
  const f = new LineFramer()
  const frames = f.push(Buffer.from('{"a":1}\r\n{"b":2}\r\n'))
  if (frames.length !== 2) throw new Error(`应 2 帧，实际 ${frames.length}`)
  if (!frames[0].toString().endsWith('\r\n')) throw new Error('CRLF 未保留（说明按 \\r\\n 误切）')
})
check('flush 取出残留半行', () => {
  const f = new LineFramer()
  f.push(Buffer.from('{"partial":'))
  const rest = f.flush()
  if (rest.toString() !== '{"partial":') throw new Error(`flush 错：${rest.toString()}`)
  if (f.flush().length !== 0) throw new Error('二次 flush 应为空')
})

console.log(`\n${passed}/${passed + failures.length} 通过。`)
if (failures.length > 0) { for (const f of failures) console.log(`  - ${f}`); process.exit(1) }
