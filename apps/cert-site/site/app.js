(() => {
  'use strict';
  const CA_PROBE = 'https://probe.home/ok';
  const LAN_PROBE = 'https://lan.progist.ru/ok';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // --- ОС и вкладки -------------------------------------------------------
  function detectOS() {
    const ua = navigator.userAgent;
    if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Android/.test(ua)) return 'android';
    if (/Windows/.test(ua)) return 'win';
    if (/Macintosh|Mac OS X/.test(ua)) return 'mac';
    if (/Linux|X11|CrOS/.test(ua)) return 'linux';
    return 'ios';
  }
  function selectTab(name) {
    $$('.tabs button').forEach(b => b.setAttribute('aria-selected', String(b.dataset.tab === name)));
    $$('.panel').forEach(p => p.classList.toggle('active', p.dataset.panel === name));
  }
  $$('.tabs button').forEach(b => b.addEventListener('click', () => selectTab(b.dataset.tab)));
  selectTab(detectOS());

  // кнопка «копировать» у блоков с командами
  $$('pre[data-copy]').forEach(pre => {
    const btn = document.createElement('button');
    btn.type = 'button'; btn.className = 'copy'; btn.textContent = 'Копировать';
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(pre.firstChild.textContent.trim()); btn.textContent = 'Готово'; }
      catch { btn.textContent = 'Не вышло'; }
      setTimeout(() => (btn.textContent = 'Копировать'), 1500);
    });
    pre.appendChild(btn);
  });

  // --- метаданные сертификата --------------------------------------------
  const fill = async (file, id) => {
    try {
      const r = await fetch(file, { cache: 'no-cache' });
      if (r.ok) $(id).textContent = (await r.text()).trim();
    } catch { /* оставляем «…» */ }
  };
  fill('subject.txt', '#meta-subject');
  fill('not-after.txt', '#meta-expiry');
  fill('fingerprint.txt', '#meta-fp');

  // --- проверка: в сети ли мы и доверяет ли клиент нашему CA -------------
  // lan.progist.ru — публичный сертификат, адрес только внутренний → «я дома?»
  // probe.home    — сертификат нашего CA → «CA установлен?»
  const box = $('#status');
  function setState(state, title, text) {
    box.dataset.state = state;
    $('#status-title').textContent = title;
    $('#status-text').textContent = text;
  }
  async function reachable(url) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 5000);
    try {
      const r = await fetch(url, { cache: 'no-store', signal: ctl.signal, credentials: 'omit' });
      return r.ok;
    } catch { return false; }
    finally { clearTimeout(timer); }
  }
  async function check() {
    setState('checking', 'Проверяю…', 'Проверяю, доверяет ли это устройство сертификатам *.home.');
    const [home, trusted] = await Promise.all([reachable(LAN_PROBE), reachable(CA_PROBE)]);
    if (trusted) {
      setState('ok', 'Сертификат установлен', 'Это устройство доверяет сертификатам *.home. Больше ничего делать не нужно.');
    } else if (home) {
      setState('fail', 'Сертификат не установлен',
        'Вы в домашней сети, но устройство пока не доверяет сертификатам *.home. Установите сертификат по инструкции ниже.');
    } else {
      setState('fail', 'Вы не в домашней сети',
        'Подключитесь к домашней сети или VPN и проверьте ещё раз. Установить сертификат можно и сейчас.');
    }
  }
  $('#recheck').addEventListener('click', check);
  check();
})();
