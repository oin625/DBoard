const $ = (id) => document.getElementById(id);

async function refresh() {
  const st = await chrome.runtime.sendMessage({ cmd: 'status' });
  const h = st.header || '';
  const names = h ? h.split(/;\s*/).map((kv) => kv.split('=')[0]) : [];
  $('count').textContent = names.length ? `${names.length} 条 cookie` : '未读到任何 cookie';
  $('names').textContent = names.length ? names.slice(0, 14).join(', ') + (names.length > 14 ? '…' : '') : '请先在上方按钮登录 ai.tmallyc.com，登录后自动捕获';
  $('pushed').textContent = st.lastViaFile
    ? `最近写文件: ${st.lastViaFile}（D 盘 cookie 已就绪）`
    : (st.lastPush ? `最近成功投递: ${st.lastPush}` : '从未成功投递');
  $('audi').textContent = st.lastAudiErr
    ? `Audi 会话桥失败: ${st.lastAudiErr}`
    : st.lastAudiPush
      ? (st.lastAudiSessionPresent
        ? `Audi 登录态已投递: ${st.lastAudiPush}`
        : `Chrome 无 Audi 登录态，已清除内嵌旧会话: ${st.lastAudiPush}`)
      : 'Audi 会话桥尚未投递';
  $('audi').style.color = st.lastAudiErr ? '#b91c1c' : (st.lastAudiPush ? '#047857' : '#6b7280');
  $('err').textContent = st.lastErr ? `⚠ ${st.lastErr}` : ''; 
  const hasSession = h.includes('session-id=');
  $('sess').textContent = hasSession
    ? `✓ session-id: ${h.match(/session-id=([^;]+)/)[1].slice(0, 24)}…`
    : '✗ 没有 session-id —— 说明还没登录成功过';
  $('sess').style.color = hasSession ? '#047857' : '#b45309';
}

$('open').addEventListener('click', async () => {
  const tab = await chrome.tabs.create({ url: 'https://ai.tmallyc.com/prd/index.html' });
  const msg = $('pushed');
  msg.textContent = '已打开登录页，等它就绪后这里会自动变绿：';
  const t = setInterval(async () => {
    const st = await chrome.runtime.sendMessage({ cmd: 'status' });
    if (st.header && st.header.includes('session-id=') && !st.lastErr) {
      clearInterval(t); msg.textContent = `✓ 已自动收割并投递（${st.lastPush || ''}）`; refresh();
    } else { msg.textContent = `等待登录态… ${st.lastErr || ''}`; }
  }, 1500);
  setTimeout(() => clearInterval(t), 120000);
});

$('push').addEventListener('click', async () => {
  const st = await chrome.runtime.sendMessage({ cmd: 'push' });
  $('pushed').textContent = st.lastErr ? `投递失败: ${st.lastErr}` : `已投递: ${st.lastPush}`;
  refresh();
});

chrome.cookies.getAll({ domain: 'tmallyc.com' }).then((cs) => {
  $('pre').textContent = `${cs.length} 个 tmallyc.com 相关 cookie（含所有子域）\n` +
    cs.slice(0, 40).map((c) => `${c.domain} ${c.name}`).join('\n');
});
refresh();
