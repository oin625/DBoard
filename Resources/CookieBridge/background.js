// DBoard Cookie Bridge v3 — 无条件周期投递, 绝不要求重新登录
const DBOARD_URL = 'http://127.0.0.1:58613/cookie';
const SITE_URL = 'https://ai.tmallyc.com/prd/index.html';
const AUDI_URL = 'https://audi.tmallyc.com/app-release';
const AUDI_BRIDGE_URL = 'http://127.0.0.1:58613/audi-cookie';
const CANARY_ORIGINS = {
  prod: 'https://canary-tmyc.tmallyc.com',
  pre: 'https://pre-i0-canary.tmallyc-inc.net',
};
let lastCanaryStatus = '尚未配对';

async function connectCanary() {
  try {
    const { canaryBridgeToken } = await chrome.storage.local.get('canaryBridgeToken');
    if (!/^[0-9a-f]{64}$/.test(canaryBridgeToken || '')) {
      lastCanaryStatus = '请在 DBoard 弹窗中点击“允许连接”';
      const r = await fetch('http://127.0.0.1:58613/canary-cookie/pair', {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(60000),
      });
      if (!r.ok) throw new Error(r.status === 429 ? '已有连接请求，请处理弹窗或稍后重试' : '未允许连接，请重新点击连接');
      const data = await r.json();
      if (!/^[0-9a-f]{64}$/.test(data.token || '')) throw new Error('配对响应无效');
      await chrome.storage.local.set({ canaryBridgeToken: data.token });
    }
    await pushCanarySessions();
  } catch (e) {
    lastCanaryStatus = e.name === 'TypeError' || e.name === 'TimeoutError'
      ? '连接未完成，请确认 DBoard 已运行并处理授权弹窗' : e.message;
  }
}

async function pushCanarySessions() {
  const { canaryBridgeToken } = await chrome.storage.local.get('canaryBridgeToken');
  if (!/^[0-9a-f]{64}$/.test(canaryBridgeToken || '')) {
    lastCanaryStatus = '尚未配对';
    return;
  }
  const statuses = [];
  for (const [environment, origin] of Object.entries(CANARY_ORIGINS)) {
    try {
      if (!await chrome.permissions.contains({ origins: [origin + '/*'] })) {
        statuses.push(`${environment}: 缺少该域名的 Cookie 读取权限`);
        continue;
      }
      const cookies = await chrome.cookies.getAll({ url: origin + '/manual/queryBizData' });
      const cookie = cookies
        .filter(c => !c.expirationDate || c.expirationDate > Date.now() / 1000)
        .sort((a, b) => b.path.length - a.path.length)
        .map(c => `${c.name}=${c.value}`).join('; ');
      const r = await fetch('http://127.0.0.1:58613/canary-cookie', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + canaryBridgeToken },
        body: JSON.stringify({ environment, origin, cookie }),
        signal: AbortSignal.timeout(3000),
        redirect: 'error',
      });
      statuses.push(`${environment}: ${r.ok ? (cookie ? 'Cookie 已同步' : environment === 'pre' ? '已连接（无需 Cookie）' : '未检测到 Cookie') : '桥接拒绝(' + r.status + ')'}`);
    } catch (_) { statuses.push(`${environment}: 同步失败，请检查DBoard和扩展权限`); }
  }
  lastCanaryStatus = statuses.join('；');
}

// Audi 的网页鉴权只认 ac-session-id；专用通道不写本地文件，也不记录 Cookie 值。
let lastAudiPush = '';
let lastAudiErr = '';
let lastAudiSessionPresent = null;

async function sendAudiCookie(body) {
  const response = await fetch(AUDI_BRIDGE_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`本机桥拒绝(${response.status})`);
  lastAudiPush = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  lastAudiErr = '';
  lastAudiSessionPresent = Boolean(body.value);
}

async function pushAudiSession() {
  try {
    const cookies = await chrome.cookies.getAll({ url: AUDI_URL, name: 'ac-session-id' });
    const cookie = cookies
      .filter((c) => !c.expirationDate || c.expirationDate > Date.now() / 1000)
      .sort((a, b) => Number(b.domain === 'audi.tmallyc.com') - Number(a.domain === 'audi.tmallyc.com'))[0];
    // Chrome 登出时也通知 WebView 移除旧会话，避免继续使用失效登录态。
    if (!cookie) {
      await sendAudiCookie({ name: 'ac-session-id', value: '' });
      return;
    }
    await sendAudiCookie({
      name: cookie.name, value: cookie.value, domain: cookie.domain,
      path: cookie.path, expirationDate: cookie.expirationDate,
    });
  } catch (error) {
    lastAudiErr = String(error && error.message || error);
  }
}

let lastPush = '';
let lastErr = '';
let lastHeader = '';
let lastViaFile = '';

async function headerString() {
  // url 匹配比 domain 更宽容: HostOnly cookie (.tmallyc.com 子域) 一网打尽
  const cs = await chrome.cookies.getAll({ url: SITE_URL });
  // 与 ⌃Q 共用的 .tmallyc.com ac-session-id 同样适用于 ai 域，不能在这里剔除。
  const all = cs.length ? cs : await chrome.cookies.getAll({ domain: 'tmallyc.com' });
  const seen = new Set();
  const parts = [];
  for (const c of all) {
    if (seen.has(c.name)) continue;         // 先 ai 精确域再泛域, 同名不重复
    seen.add(c.name);
    parts.push(`${c.name}=${c.value}`);
  }
  return parts.join('; ');
}

async function push(force) {
  try {
    const header = await headerString();
    if (!header) { lastErr = '浏览器里还没有 ai.tmallyc.com 的任何 cookie（未登录过）'; return; }
    // DBoard 重启后会丢失内存态；每分钟重新投递，接收端仅在会话变化时验证/刷新。
    lastErr = '';
    let deliveredLocally = false;
    try {
      const r = await fetch(DBOARD_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain', 'X-DBoard': 'bridge' },
        body: header,
      });
      if (r.ok) {
        lastPush = new Date().toLocaleTimeString('zh-CN', { hour12: false });
        deliveredLocally = true;
      } else { lastErr = `DBoard 拒绝(${r.status})`; }
    } catch (e) { lastErr = `本地通道不通(${e && e.message || e})`; }
    // 文件兜底只在本机 HTTP 投递失败时尝试，避免把非必需通道错误报成整体失败。
    if (!deliveredLocally) {
      try {
        const url = URL.createObjectURL(new Blob([header], { type: 'text/plain' }));
        await chrome.downloads.download({ url, filename: 'DBoard-cookie.txt',
                                          conflictAction: 'overwrite', saveAs: false });
        lastViaFile = new Date().toLocaleTimeString('zh-CN', { hour12: false });
      } catch (e) { lastErr += ` | 文件通道也失败: ${e && e.message || e}`; }
    }
    lastHeader = header;
  } catch (e) { lastErr = String(e && e.message || e); }
  updateBadge();
}

function updateBadge() {
  const has = lastHeader.includes('session-id=');
  chrome.action.setBadgeText({ text: lastErr ? '!' : (has ? 'ON' : '?') });
  chrome.action.setBadgeBackgroundColor({ color: lastErr ? '#dc2626' : (has ? '#16a34a' : '#f59e0b') });
  chrome.action.setTitle({
    title: lastErr ? `DBoard 桥: ${lastErr}`
      : `DBoard 桥: 已投递 ${lastPush || '-'}\n点图标可手动同步`,
  });
}

chrome.runtime.onMessage.addListener((m, _s, sendResponse) => {
  const snap = () => ({ lastPush, lastErr, header: lastHeader || '', lastViaFile, lastAudiPush, lastAudiErr, lastAudiSessionPresent, lastCanaryStatus });
  if (m && m.cmd === 'status') sendResponse(snap());
  if (m && m.cmd === 'canary-connect') {
    connectCanary().then(() => sendResponse({ lastCanaryStatus }));
    return true;
  }
  if (m && m.cmd === 'push') {
    Promise.all([push(true), pushAudiSession(), pushCanarySessions()]).then(() => sendResponse(Object.assign(snap(), { done: true })));
    return true;
  }
});

chrome.alarms.create('beat', { periodInMinutes: 1 });   // v3: 60 秒无条件兜底, 不依赖任何"变化"事件
chrome.alarms.onAlarm.addListener(() => { push(false); pushAudiSession(); pushCanarySessions(); });
chrome.cookies.onChanged.addListener(({ cookie }) => {
  if (cookie.domain && cookie.domain.includes('tmallyc')) {
    setTimeout(() => { push(true); pushAudiSession(); pushCanarySessions(); }, 500);
  }
});
chrome.runtime.onStartup.addListener(() => setTimeout(() => { push(true); pushAudiSession(); }, 2000));
chrome.runtime.onInstalled.addListener(() => setTimeout(() => { push(true); pushAudiSession(); }, 1000));
push(true);
pushAudiSession();
pushCanarySessions();
