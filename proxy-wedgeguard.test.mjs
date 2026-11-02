// 引擎占用守卫的回归测试：单元（纯逻辑）+ 集成（真实代理进程包一个假慢服务器）。
// 运行：node proxy-wedgeguard.test.mjs
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { CallTracker, inspectClientFrame, observeServerFrame } from './mcp-schema-fix-proxy.mjs'

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

function checkAsync(name, fn) {
  return fn().then(
    () => {
      passed += 1
      console.log(`  PASS  ${name}`)
    },
    (error) => {
      failures.push({ name, message: error?.message ?? String(error) })
      console.log(`  FAIL  ${name}`)
      console.log(`        → ${error?.message ?? error}`)
    },
  )
}

const callFrame = (id, name) => Buffer.from(`${JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: {} } })}\n`)
const resultFrame = (id, ms) => Buffer.from(`${JSON.stringify({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `took ${ms}ms` }] } })}\n`)

console.log('CallTracker')
check('begin/end 记录耗时', () => {
  const t = new CallTracker()
  t.begin(1, 'evaluate_matlab_code', 1000)
  const done = t.end(1, 61000)
  assert.equal(done.name, 'evaluate_matlab_code')
  assert.equal(done.durationMs, 60000)
  assert.equal(t.size, 0)
})
check('end 未知 id 返回 null', () => {
  const t = new CallTracker()
  assert.equal(t.end(99, 1000), null)
})
check('blocker：在途超过阈值才报', () => {
  const t = new CallTracker({ wedgeAfterMs: 5000, staleMs: 60000 })
  t.begin(1, 'a', 0)
  assert.equal(t.blocker(4000), null)
  const b = t.blocker(6000)
  assert.equal(b.name, 'a')
  assert.equal(b.ageMs, 6000)
})
check('blocker：僵尸条目超 stale 自动清除，不永久误判', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 10000 })
  t.begin(1, 'ghost', 0)
  assert.equal(t.blocker(20000), null)
  assert.equal(t.size, 0)
})
check('blocker：多个在途时报最老的那个', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'newer', 5000)
  t.begin(2, 'older', 1000)
  const b = t.blocker(9000)
  assert.equal(b.name, 'older')
})
check('end 后条目移除，不再挡新调用', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'a', 0)
  t.end(1, 2000)
  t.begin(2, 'b', 3000)
  assert.equal(t.blocker(3500), null)
})

console.log('\ninspectClientFrame')
check('tools/call：无 blocker 时转发并登记', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  const v = inspectClientFrame(callFrame(7, 'session_info'), t, 0)
  assert.equal(v.forward, true)
  assert.equal(v.tracked.id, '7')
  assert.equal(v.tracked.name, 'session_info')
})
check('tools/call：blocker 在途时秒回拒绝且 id 对应', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'evaluate_matlab_code', 0)
  const v = inspectClientFrame(callFrame(2, 'session_info'), t, 5000)
  assert.equal(v.forward, false)
  const msg = JSON.parse(v.response.toString('utf8'))
  assert.equal(msg.id, 2)
  assert.equal(msg.result.isError, true)
  assert.ok(msg.result.content[0].text.includes('evaluate_matlab_code'))
  assert.ok(msg.result.content[0].text.includes('Get-Process MATLAB'))
  assert.equal(t.size, 1, '被拒绝的调用不进入在途台账')
})
check('通知帧（无 id）原样转发', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'a', 0)
  const note = Buffer.from(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`)
  const v = inspectClientFrame(note, t, 5000)
  assert.equal(v.forward, true)
  assert.equal(v.tracked, null)
})
check('解析失败的帧原样转发（不引入解析风险）', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  const v = inspectClientFrame(Buffer.from('not json\n'), t, 0)
  assert.equal(v.forward, true)
})
check('ping 不追踪也不拒绝', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'a', 0)
  const ping = Buffer.from(`${JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'ping' })}\n`)
  const v = inspectClientFrame(ping, t, 5000)
  assert.equal(v.forward, true)
  assert.equal(v.tracked, null)
  assert.equal(t.size, 1)
})

console.log('\nobserveServerFrame')
check('应答配对并返回耗时；慢调用不改写帧', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  t.begin(1, 'evaluate_matlab_code', 0)
  const frame = resultFrame(1, 12000)
  const done = observeServerFrame(frame, t, 12000)
  assert.equal(done.durationMs, 12000)
  assert.equal(t.size, 0)
})
check('未知 id 的应答不产生耗时', () => {
  const t = new CallTracker({ wedgeAfterMs: 1000, staleMs: 60000 })
  assert.equal(observeServerFrame(resultFrame(42, 5), t, 100), null)
})
check('通知/残帧安全返回 null', () => {
  const t = new CallTracker()
  assert.equal(observeServerFrame(Buffer.from('garbage\n'), t, 0), null)
  assert.equal(observeServerFrame(Buffer.from(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/x' })}\n`), t, 0), null)
})

console.log('\n集成：真实代理进程 × 假慢服务器')
await checkAsync('占用中的引擎让第二个调用秒回诊断，第一个照常返回', async () => {
  const fakeServer = `
    process.stdin.setEncoding('utf8');
    let buf = '';
    process.stdin.on('data', (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf('\\n')) !== -1) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.method === 'tools/call') {
          setTimeout(() => {
            process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: 'slow-ok' }] } }) + '\\n');
          }, 1500);
        } else if (m.id !== undefined) {
          process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, result: {} }) + '\\n');
        }
      }
    });
  `
  const child = spawn(process.execPath, ['-e', fakeServer], { stdio: ['pipe', 'pipe', 'pipe'] })
  const proxy = spawn(process.execPath, ['mcp-schema-fix-proxy.mjs', '--', process.execPath, '-e', fakeServer], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, MC_WEDGE_AFTER_MS: '700', MC_WEDGE_STALE_MS: '600000', MC_SLOW_CALL_MS: '100000' },
  })
  try {
    const events = []
    let buf = ''
    proxy.stdout.on('data', (c) => {
      buf += c.toString('utf8')
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        try { events.push({ at: Date.now(), msg: JSON.parse(line) }) } catch {}
      }
    })
    let stderrTail = ''
    proxy.stderr.on('data', (c) => { stderrTail += c.toString('utf8') })
    // initialize 握手（fake server 对一切带 id 的请求都秒回 {}）
    proxy.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 0, method: 'initialize', params: {} })}\n`)
    await new Promise((r) => setTimeout(r, 300))
    const t0 = Date.now()
    proxy.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'evaluate_matlab_code', arguments: {} } })}\n`)
    await new Promise((r) => setTimeout(r, 900)) // 第一个调用仍在途（阈值 700ms 已过）
    proxy.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'session_info', arguments: {} } })}\n`)
    // 等到第一个调用 1500ms 后的真实应答
    await new Promise((r) => setTimeout(r, 2200))
    const refusals = events.filter((e) => e.msg.id === 2 && e.msg.result?.isError)
    const slowOk = events.filter((e) => e.msg.id === 1 && e.msg.result?.content?.[0]?.text === 'slow-ok')
    assert.equal(refusals.length, 1, `id=2 应恰好收到一次拒绝，收到 ${JSON.stringify(events.map((e) => e.msg.id))}`)
    assert.ok(refusals[0].at - t0 < 1600, '拒绝必须秒回（远早于第一个调用的 1500ms 完成）')
    assert.ok(refusals[0].msg.result.content[0].text.includes('evaluate_matlab_code'))
    assert.equal(slowOk.length, 1, '第一个调用最终照常返回')
    assert.equal(slowOk[0].msg.result.content[0].text, 'slow-ok')
  } finally {
    try { proxy.kill() } catch {}
    try { child.kill() } catch {}
  }
})

console.log(`\n${passed}/${passed + failures.length} 通过。`)
if (failures.length > 0) {
  console.log('失败清单：')
  for (const f of failures) console.log(`  - ${f.name}: ${f.message}`)
  process.exitCode = 1
}
