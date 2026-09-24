import { writeFile } from 'node:fs/promises';

const socket = new WebSocket('ws://127.0.0.1:42207/devtools/browser/f4a5148a-7b56-49c0-a404-20d56bd33fd6');
await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
let nextID = 0;
const pending = new Map();
const listeners = new Map();
socket.addEventListener('message', ({ data }) => {
  const value = JSON.parse(data);
  if (value.id) {
    const request = pending.get(value.id);
    pending.delete(value.id);
    if (value.error) request.reject(new Error(JSON.stringify(value.error)));
    else request.resolve(value.result);
  } else if (listeners.has(value.method)) {
    listeners.get(value.method)(value);
    listeners.delete(value.method);
  }
});
function call(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++nextID;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });
}
const { targetId } = await call('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await call('Target.attachToTarget', { targetId, flatten: true });
await call('Page.enable', {}, sessionId);
await call('Emulation.setDeviceMetricsOverride', { width: 500, height: 620, deviceScaleFactor: 1, mobile: false }, sessionId);
const base = 'file://<local NexGenVideo checkout>/.claude/worktrees/codex-fix-open-bugs/docs/ui/generation-batches.html';
async function navigate(state) {
  const loaded = new Promise(resolve => listeners.set('Page.loadEventFired', resolve));
  await call('Page.navigate', { url: base + '?state=' + state }, sessionId);
  await loaded;
}
async function evaluate(expression) {
  const value = await call('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
  if (value.exceptionDetails) throw new Error(JSON.stringify(value.exceptionDetails));
  return value.result.value;
}
function expect(value, message) { if (!value) throw new Error(message); }
async function capture(path) {
  const { data } = await call('Page.captureScreenshot', { format: 'png' }, sessionId);
  await writeFile(path, Buffer.from(data, 'base64'));
}
await navigate('unpriced');
expect(await evaluate(`[...document.querySelectorAll('.row')].every(row => row.querySelector('.expand').getAttribute('aria-expanded') === String(!row.querySelector('.details').hidden))`), 'Every initial expansion attribute must match visibility');
await evaluate(`document.querySelector('#unpriced .remove').click()`);
const afterRemoval = await evaluate(`(() => {const section=document.querySelector('#unpriced');return {count:section.querySelectorAll('.row').length,first:section.querySelector('.row').dataset.number,retry:!section.querySelector('.retry').disabled,route:!section.querySelector('.change-route').disabled,approve:!section.querySelector('.primary').disabled}})()`);
expect(afterRemoval.count === 12 && afterRemoval.first === '2' && afterRemoval.retry && !afterRemoval.route && !afterRemoval.approve, 'Removing one unpriced item must leave remaining pricing recoverable');
await capture('/tmp/ngv-task7-round1-after-removal.png');
await evaluate(`document.querySelector('#unpriced [data-number="3"] input').click()`);
expect(await evaluate(`!document.querySelector('#unpriced .change-route').disabled && !document.querySelector('#unpriced .retry').disabled`), 'Selecting the remaining unpriced item enables route recovery');
await capture('/tmp/ngv-task7-round1-selected-recovery.png');
await evaluate(`document.querySelector('#unpriced .remove').click()`);
expect(await evaluate(`(() => {const section=document.querySelector('#unpriced');return !section.querySelector('.primary').disabled && section.querySelector('.totals span').textContent === 'Estimated total: €2.75' && getComputedStyle(section.querySelector('.recovery')).display === 'none'})()`), 'Removing every unpriced row must restore priced approval and hide pricing recovery');
expect(await evaluate(`(() => {const section=document.querySelector('#busy');const input=section.querySelector('input');input.checked=true;input.dispatchEvent(new Event('change'));return [...section.querySelectorAll('.retry,.change-route,.remove,.primary')].every(button=>button.disabled)})()`), 'Busy state must keep all mutation and recovery buttons disabled');
await navigate('expanded');
expect(await evaluate(`document.querySelector('#expanded .expand').getAttribute('aria-expanded') === 'true' && !document.querySelector('#expanded .details').hidden`), 'Initially expanded detail must expose aria-expanded=true');
await capture('/tmp/ngv-task7-round1-expanded.png');
await evaluate(`document.querySelector('#expanded .expand').click()`);
expect(await evaluate(`document.querySelector('#expanded .expand').getAttribute('aria-expanded') === 'false' && document.querySelector('#expanded .details').hidden`), 'Collapsing detail must update both aria and visibility');
await evaluate(`document.querySelector('#expanded .expand').click()`);
expect(await evaluate(`document.querySelector('#expanded .expand').getAttribute('aria-expanded') === 'true' && !document.querySelector('#expanded .details').hidden`), 'Re-expanding detail must update both aria and visibility');
console.log(JSON.stringify({ afterRemoval, checks: 'initial/all-row expansion parity, removal recovery, selected route recovery, all-priced transition, busy controls, expansion toggles verified', screenshots: ['/tmp/ngv-task7-round1-after-removal.png', '/tmp/ngv-task7-round1-selected-recovery.png', '/tmp/ngv-task7-round1-expanded.png'] }, null, 2));
await call('Target.closeTarget', { targetId });
await call('Browser.close');
socket.close();
