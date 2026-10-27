// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
const state = { status: null, selectedRunID: null, selectedRun: null, file: null, busy: false };
const $ = (id) => document.getElementById(id);
const api = async (path, options = {}) => {
  const response = await fetch(path, { credentials: 'same-origin', ...options });
  const type = response.headers.get('content-type') || '';
  const body = type.includes('application/json') ? await response.json() : await response.text();
  if (!response.ok) throw new Error(typeof body === 'string' ? body : (body.error || `请求失败 (${response.status})`));
  return body;
};
const escapeHTML = (value = '') => String(value).replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
const formatBytes = (bytes = 0) => bytes < 1024 * 1024 ? `${Math.max(0, Math.round(bytes / 1024))} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;
const statusText = (status) => ({ queued: '排队中', running: '正在运行', processing: '正在处理', training: '正在训练', ready_for_training: '训练输入已准备', completed: '已完成', cancelled: '已取消', interrupted: '已中断', failed: '失败' }[status] || status || '未知');
const stageText = (run) => [statusText(run.status), run.stage, run.error].filter(Boolean).join(' · ');

function setConnection(ok, text) {
  const badge = $('connection');
  badge.textContent = text;
  badge.className = `badge ${ok ? 'ok' : 'bad'}`;
}
function setBusy(busy) {
  state.busy = busy;
  $('upload-button').disabled = busy || !state.file;
  $('start-button').disabled = busy || !$('inbox-select').value || Boolean(state.status?.activeRunId);
}
function renderEnvironment(environment = {}) {
  const labels = { ffmpeg: 'FFmpeg', photogrammetry: '摄影测量', trainer: '训练器', metal: 'Metal', viewer: 'SuperSplat Viewer' };
  const list = $('environment-list');
  list.replaceChildren();
  Object.entries(labels).forEach(([key, name]) => {
    const item = document.createElement('span');
    item.className = `tool ${environment[key] ? '' : 'missing'}`;
    item.textContent = `${environment[key] ? '✓' : '×'} ${name}`;
    list.append(item);
  });
  const missingMetal = !environment.metal || !environment.trainer;
  $('toolchain-note').textContent = missingMetal
    ? '缺少 Metal 或训练器：请安装完整 Xcode 与 Metal Toolchain；可以先导入视频和查看已有模型。'
    : '本机训练工具链已就绪。';
  $('environment-summary').textContent = missingMetal ? '训练工具链未完整' : '训练工具链就绪';
}
function renderInbox(inbox = []) {
  const select = $('inbox-select');
  const old = select.value;
  select.replaceChildren(new Option(inbox.length ? '请选择收件箱文件' : '收件箱为空', ''));
  inbox.forEach((entry) => select.add(new Option(`${entry.name}（${formatBytes(entry.size)}）`, entry.name)));
  select.value = inbox.some((entry) => entry.name === old) ? old : '';
}
function renderRuns(runs = []) {
  const list = $('runs-list');
  list.replaceChildren();
  $('runs-empty').hidden = runs.length > 0;
  runs.forEach((run) => {
    const template = $('run-template').content.cloneNode(true);
    const button = template.querySelector('.run-item');
    button.dataset.id = run.id;
    button.classList.toggle('selected', run.id === state.selectedRunID);
    template.querySelector('.run-id').textContent = run.id;
    template.querySelector('.run-source').textContent = run.source || '未知输入';
    template.querySelector('.run-stage').textContent = stageText(run);
    button.addEventListener('click', () => selectRun(run.id));
    list.append(template);
  });
}
function renderActiveRun(status) {
  const active = status.activeRunId;
  $('active-run').textContent = active ? `活动任务：${active}` : '没有活动任务';
  $('start-note').textContent = active ? '一次只允许一个活动任务。请等待、取消或继续当前任务。' : '默认 Quick 演示使用 4,000 次迭代。';
}
function renderRunDetail(run) {
  state.selectedRun = run;
  if (!run) return;
  const status = run.status || 'unknown';
  $('run-status').textContent = statusText(status);
  $('run-status').className = `badge ${status === 'completed' ? 'ok' : status === 'failed' ? 'bad' : 'neutral'}`;
  $('run-description').textContent = `${run.source || '未知输入'}：${stageText(run)}`;
  $('run-log').textContent = run.log || '服务尚未输出日志。';
  const active = ['queued', 'running', 'processing', 'training'].includes(status);
  const activeElsewhere = Boolean(state.status?.activeRunId && state.status.activeRunId !== run.id);
  $('retry-button').disabled = !run.canResume || state.busy || activeElsewhere;
  $('cancel-button').disabled = !(active && state.status?.activeRunId === run.id) || state.busy;
  const exportLink = $('download-model');
  exportLink.href = run.exportURL || '#';
  exportLink.classList.toggle('disabled', !run.exportURL);
  const viewerURL = run.modelReady && run.viewerURL ? run.viewerURL : null;
  $('open-viewer').href = viewerURL || '#';
  $('open-viewer').classList.toggle('disabled', !viewerURL);
  $('viewer-frame').hidden = !viewerURL;
  $('viewer-placeholder').hidden = Boolean(viewerURL);
  if (viewerURL && $('viewer-frame').src !== new URL(viewerURL, window.location.href).href) $('viewer-frame').src = viewerURL;
  if (!viewerURL && $('viewer-frame').hasAttribute('src')) $('viewer-frame').removeAttribute('src');
}
async function refreshStatus() {
  try {
    const status = await api('/api/status');
    state.status = status;
    $('inbox-path').textContent = `收件目录：${status.inboxPath}`;
    setConnection(true, '本地服务已连接');
    renderEnvironment(status.environment);
    renderInbox(status.inbox);
    renderRuns(status.runs);
    renderActiveRun(status);
    setBusy(state.busy);
    if (state.selectedRunID) await loadRun(state.selectedRunID, false);
  } catch (error) {
    setConnection(false, '本地服务不可用');
    $('environment-summary').textContent = '等待服务启动';
    $('toolchain-note').textContent = error.message;
  }
}
async function loadRun(id, force = true) {
  if (!id) return;
  try {
    const run = await api(`/api/runs/${encodeURIComponent(id)}`);
    if (state.selectedRunID !== id && !force) return;
    state.selectedRunID = id;
    renderRunDetail(run);
    renderRuns(state.status?.runs || []);
  } catch (error) {
    $('run-log').textContent = `读取运行失败：${error.message}`;
  }
}
async function selectRun(id) {
  state.selectedRunID = id;
  await loadRun(id);
}
async function upload() {
  if (!state.file) return;
  setBusy(true);
  try {
    const result = await api(`/api/upload?name=${encodeURIComponent(state.file.name)}`, { method: 'POST', headers: { 'Content-Type': state.file.type || 'application/octet-stream' }, body: state.file });
    $('upload-name').textContent = `已放入收件箱：${result.name}`;
    state.file = null;
    $('video-file').value = '';
    await refreshStatus();
    $('inbox-select').value = result.name;
  } catch (error) {
    $('upload-name').textContent = `上传失败：${error.message}`;
  } finally { setBusy(false); }
}
async function startRun() {
  const file = $('inbox-select').value;
  const iterations = Number($('iterations').value);
  if (!file || !Number.isInteger(iterations) || iterations < 10 || iterations > 20000) {
    $('start-note').textContent = '请选择收件箱视频，并填写 10 到 20,000 的整数迭代次数。';
    return;
  }
  setBusy(true);
  try {
    const result = await api('/api/runs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ file, iterations }) });
    state.selectedRunID = result.id;
    await refreshStatus();
    await loadRun(result.id);
  } catch (error) {
    $('start-note').textContent = `无法开始：${error.message}`;
  } finally { setBusy(false); }
}
async function postRunAction(action) {
  if (!state.selectedRunID) return;
  setBusy(true);
  try {
    await api(`/api/runs/${encodeURIComponent(state.selectedRunID)}/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    await refreshStatus();
    await loadRun(state.selectedRunID);
  } catch (error) {
    $('run-log').textContent = `${action === 'cancel' ? '取消' : '重试'}失败：${error.message}\n${$('run-log').textContent}`;
  } finally { setBusy(false); }
}

$('video-file').addEventListener('change', (event) => {
  state.file = event.target.files?.[0] || null;
  $('upload-name').textContent = state.file ? `${state.file.name}（${formatBytes(state.file.size)}）` : '尚未选择文件';
  setBusy(state.busy);
});
$('inbox-select').addEventListener('change', () => setBusy(state.busy));
$('upload-button').addEventListener('click', upload);
$('refresh-button').addEventListener('click', refreshStatus);
$('start-button').addEventListener('click', startRun);
$('retry-button').addEventListener('click', () => postRunAction('resume'));
$('cancel-button').addEventListener('click', () => postRunAction('cancel'));

await refreshStatus();
window.setInterval(refreshStatus, 3000);
