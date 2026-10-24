/* The web side of TNB/1 in the panel stand-in of the iOS tests (ios/TraklyUITests/Panel/server.mjs;
   docs/specs/phase10-apps-and-stores.md §B1, §B4, §B7, §F1–§F3). It behaves like the panel's app mode
   (lib/native/appMode.ts, appChrome.ts, linkInterceptor.ts, the order form's useNativeIntake): `hello` within 1,000 ms,
   then `config`, `tabs`, `page` after every visit and `ready`; client-side visits with pushState (as Inertia), `route`
   for another context, `compose` for a bare «ثبت سفارش», the order form's `intake.take` / `intake.line` /
   `intake.pending` / `product.image`, files, print, share, scan and the More page's switches. Without a
   TraklyNative object or the app token it is a plain page. */
(() => {
    'use strict';

    const root = document.documentElement;
    const native = window.TraklyNative || null;
    const DRAFT_KEY = 'trakly.stub.draft';
    const TAB_KEY = 'trakly.stub.tabs';
    const LOCK_KEY = 'trakly.stub.lock';
    const ROOTS = { home: '/app', orders: '/app/orders', customers: '/app/customers', more: '/app/more' };
    let meta = readMeta();
    let hello = null;
    let seq = 0;
    let depth = 0;
    let dirty = false;
    let overlay = null;
    let titleVisible = true;
    let readySent = false;
    let lastPage = '';
    let lastTabs = '';
    const pending = new Map();

    function readMeta() {
        const element = document.getElementById('trakly-page');
        return element ? JSON.parse(element.textContent) : null;
    }

    const app = () => hello !== null;
    const hasFeature = (feature) => app() && (hello.features || []).includes(feature);
    const isOrderForm = () => /^\/app\/orders\/(create|quick|\d+\/edit)$/.test(location.pathname);

    // ---- transport ----------------------------------------------------------------------------------------------------

    function nextId() {
        seq += 1;
        return 'w' + Date.now().toString(36) + '_' + seq;
    }

    function post(message) {
        if (native) native.postMessage(JSON.stringify(message));
    }

    function notify(type, body) {
        post({ v: 1, type, ...(body || {}) });
    }

    function request(type, body, timeout = 15000) {
        return new Promise((resolve) => {
            if (!native) return resolve(null);
            const id = nextId();
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve(null);
            }, timeout);
            pending.set(id, (reply) => {
                clearTimeout(timer);
                resolve(reply);
            });
            post({ v: 1, id, type, ...(body || {}) });
        });
    }

    function onMessage(event) {
        let message;
        try {
            message = JSON.parse(event.data);
        } catch {
            return;
        }
        if (message.re && pending.has(message.re)) {
            const done = pending.get(message.re);
            pending.delete(message.re);
            done(message);
            return;
        }
        const handler = HANDLERS[message.type];
        Promise.resolve(handler ? handler(message) : {}).then((body) => {
            if (message.id) post({ v: 1, re: message.id, ...(body || {}) });
        });
    }

    // ---- chrome --------------------------------------------------------------------------------------------------------

    const resolvedDark = () => root.classList.contains('dark');

    function pageMessage() {
        const night = meta.night || meta.context === 'auth' || (meta.context === 'standalone' && meta.night);
        return {
            context: meta.context,
            tab: meta.tab || null,
            title: meta.title || '',
            titleVisible,
            back: meta.back || null,
            refreshable: !!meta.refreshable && !overlay,
            dirty,
            overlay: !!overlay,
            search: !!meta.search,
            action: meta.action || null,
            tone: night || resolvedDark() ? 'night' : 'day',
        };
    }

    function draftAt() {
        try {
            const draft = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null');
            return draft && Date.now() - draft.at < 30 * 60000 ? draft.at : null;
        } catch {
            return null;
        }
    }

    function publish(force) {
        if (!app() || !meta) return;
        const message = pageMessage();
        const json = JSON.stringify(message);
        if (force || json !== lastPage) {
            lastPage = json;
            notify('page', message);
        }
        if (meta.context !== 'auth' && meta.context !== 'standalone' && meta.tabs) {
            const at = draftAt();
            const tabs = JSON.stringify({ ...meta.tabs, draft: at ? { at } : null });
            if (force || tabs !== lastTabs) {
                lastTabs = tabs;
                notify('tabs', JSON.parse(tabs));
            }
        }
        if (!readySent) {
            readySent = true;
            requestAnimationFrame(() => requestAnimationFrame(() => notify('ready', {})));
        }
    }

    /** The page's h1 in view or not (the native bar shows the title only while it is not, §B4.1 `title`). */
    function headingVisible() {
        const heading = document.querySelector('[data-page-title]');
        if (!heading) return false;
        const box = heading.getBoundingClientRect();
        return box.bottom > 4 && box.top < window.innerHeight;
    }

    function watchTitle() {
        titleVisible = headingVisible();
    }

    window.addEventListener('scroll', () => {
        const visible = headingVisible();
        if (visible !== titleVisible) {
            titleVisible = visible;
            notify('title', { visible });
            publish(false);
        }
    }, { passive: true });

    function applyTheme(resolved) {
        root.classList.toggle('dark', resolved === 'dark');
    }

    function applyInsets(insets) {
        root.style.setProperty('--app-inset-top', `${Math.max(0, insets?.top || 0)}px`);
        root.style.setProperty('--app-inset-bottom', `${Math.max(0, insets?.bottom || 0)}px`);
    }

    // ---- visits (Inertia-like) ------------------------------------------------------------------------------------------

    function remember() {
        if ((meta.context === 'tab' || meta.context === 'push') && meta.tab) {
            try {
                const memory = JSON.parse(sessionStorage.getItem(TAB_KEY) || '{}');
                memory[meta.tab] = location.pathname + location.search;
                sessionStorage.setItem(TAB_KEY, JSON.stringify(memory));
            } catch {
                // a blocked store only loses the memory
            }
        }
    }

    async function fetchPage(url) {
        const response = await fetch(url, { headers: { 'X-Trakly-Visit': '1' }, credentials: 'same-origin' });
        if (response.status === 409) {
            location.href = '/login';
            return null;
        }
        if (!response.ok) {
            location.href = url;
            return null;
        }
        return response.json();
    }

    /** A visit that belongs to another context goes to native (`route`), or `compose` for a bare «ثبت سفارش». */
    async function routed(url, next) {
        if (!app()) return false;
        const target = new URL(url, location.href);
        if (meta.context === 'modal' && next.context !== 'modal') {
            const reply = await request('route', { url: target.href, context: next.context === 'tab' ? 'tab' : 'push', tab: next.tab || null });
            notify('modal.close', {});
            return reply?.handled === true;
        }
        if (next.context === 'modal' && meta.context !== 'modal') {
            if (target.pathname === '/app/orders/create' && target.search === '' && hasFeature('intake')) {
                notify('compose', {});
                return true;
            }
            const reply = await request('route', { url: target.href, context: 'modal', tab: null });
            return reply?.handled === true;
        }
        if ((next.context === 'tab' || next.context === 'push') && next.tab && next.tab !== meta.tab && meta.context !== 'auth') {
            const reply = await request('route', { url: target.href, context: next.context, tab: next.tab });
            return reply?.handled === true;
        }
        return false;
    }

    async function visit(url, { replace = false, inPlace = false } = {}) {
        const target = new URL(url, location.href);
        if (target.origin !== location.origin) {
            await request('open.external', { url: target.href });
            return;
        }
        if (!target.pathname.startsWith('/app')) {
            location.href = target.href;
            return;
        }
        const data = await fetchPage(target.pathname + target.search);
        if (!data) return;
        if (!inPlace && (await routed(target.href, data.meta))) return;
        swap(data, replace);
    }

    function swap(data, replace) {
        document.getElementById('main').innerHTML = data.html;
        meta = data.meta;
        document.title = meta.title;
        document.body.className = `ctx-${meta.context}${meta.night ? ' night' : ''}`;
        if (replace) {
            history.replaceState({ stub: true }, '', data.url);
        } else {
            history.pushState({ stub: true }, '', data.url);
            depth += 1;
        }
        window.scrollTo(0, 0);
        dirty = false;
        overlay = null;
        mount();
        remember();
        lastPage = '';
        publish(true);
    }

    window.addEventListener('popstate', async () => {
        depth = Math.max(0, depth - 1);
        const data = await fetchPage(location.pathname + location.search);
        if (!data) return;
        document.getElementById('main').innerHTML = data.html;
        meta = data.meta;
        document.title = meta.title;
        document.body.className = `ctx-${meta.context}${meta.night ? ' night' : ''}`;
        dirty = false;
        overlay = null;
        mount();
        remember();
        lastPage = '';
        publish(true);
    });

    document.addEventListener('click', (event) => {
        const link = event.target.closest?.('a[href]');
        if (!link || event.defaultPrevented) return;
        const href = link.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        const target = new URL(href, location.href);
        if (target.origin === location.origin && target.pathname.startsWith('/app')) {
            event.preventDefault();
            visit(target.href);
        } else if (app()) {
            event.preventDefault();
            request('open.external', { url: target.href });
        }
    });

    // ---- native → web --------------------------------------------------------------------------------------------------

    const HANDLERS = {
        back: async () => {
            if (overlay) {
                closeOverlay();
                return { handled: true };
            }
            if (isOrderForm() && dirty) {
                saveDraft();
                // The kept draft reaches native with `tabs.draft` (S4 then offers «ادامه پیش نویس سفارش»).
                publish(true);
                notify('modal.close', {});
                return { handled: true };
            }
            if (depth > 0) {
                history.back();
                return { handled: true };
            }
            return { handled: false };
        },
        tab: ({ key, reselect }) => {
            if (reselect) {
                if (meta.context === 'tab' && meta.tab === key) {
                    window.scrollTo({ top: 0, behavior: 'smooth' });
                } else {
                    visit(ROOTS[key] || '/app', { inPlace: true });
                }
                return;
            }
            let remembered = null;
            try {
                remembered = JSON.parse(sessionStorage.getItem(TAB_KEY) || '{}')[key];
            } catch {
                remembered = null;
            }
            visit(remembered || ROOTS[key] || '/app', { inPlace: true });
        },
        refresh: () => visit(location.pathname + location.search, { replace: true, inPlace: true }),
        visit: async ({ url }) => {
            await visit(url);
            return { handled: true };
        },
        search: () => openSearch(),
        action: ({ id }) => {
            if (id === 'print') printInvoice();
        },
        appearance: ({ resolved }) => {
            applyTheme(resolved);
            publish(false);
        },
        insets: (body) => applyInsets(body),
        appState: () => undefined,
        'intake.fetch': ({ url, capture }) => fakeRead(url, capture),
        'intake.offer': async ({ intakeId }) => {
            if (!isOrderForm()) return { ok: false };
            await take(intakeId);
            return { ok: true };
        },
    };

    // ---- the server's product read (product-link) ----------------------------------------------------------------------

    async function fakeRead(url, capture) {
        const path = new URL(url).pathname;
        const response = await fetch('/app/orders/product-link', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(capture ? { url, capture } : { url, ext: true }),
        });
        if (response.status === 409) return { ok: false, reason: 'session', message: '' };
        const data = await response.json();
        if (data.ok) return { ok: true, product: data.product, source: capture ? 'capture' : 'server' };
        if (!capture && path.startsWith('/dev/shop/')) return { ok: false, reason: 'blocked', message: 'این سایت به سرور Trakly اجازه خواندن نمی دهد.' };
        return { ok: false, reason: data.reason || 'unreachable', message: data.message || '' };
    }

    // ---- overlays -------------------------------------------------------------------------------------------------------

    function openSearch() {
        closeOverlay();
        overlay = document.createElement('div');
        overlay.className = 'sheet';
        overlay.innerHTML = '<div class="sheet-body"><input placeholder="جستجو در منو و سفارش ها" data-id="search-input"><button class="ghost" data-id="search-close">بستن</button></div>';
        document.body.appendChild(overlay);
        overlay.querySelector('[data-id="search-close"]').addEventListener('click', closeOverlay);
        publish(false);
    }

    function closeOverlay() {
        if (overlay) {
            overlay.remove();
            overlay = null;
            publish(false);
        }
    }

    // ---- page behaviour -------------------------------------------------------------------------------------------------

    function status(id, text) {
        const element = document.querySelector(`[data-id="${id}"]`);
        if (element) element.textContent = text;
    }

    function printInvoice() {
        request('print', { url: `${location.origin}/app/orders/print/invoices?ids=1160`, title: 'فاکتور فروش' });
    }

    async function exportFile() {
        const response = await fetch('/app/orders/export', { credentials: 'same-origin' });
        const bytes = new Uint8Array(await response.arrayBuffer());
        let binary = '';
        for (const byte of bytes) binary += String.fromCharCode(byte);
        await request('file.save', { name: 'orders.csv', mime: 'text/csv', data: btoa(binary) }, 60000);
    }

    function lineTemplate(key) {
        return `<div class="card line-edit" data-line="${key}"><label>لینک یا شرح کالا<input class="line-url" dir="ltr" data-id="line-url" placeholder="https://"></label>
          <div class="line-result"></div><button class="ghost" data-id="line-fetch">دریافت اطلاعات</button></div>`;
    }

    function addLine(key) {
        const lines = document.getElementById('lines');
        if (!lines) return null;
        const id = key || 'row-' + (lines.children.length + 1);
        lines.insertAdjacentHTML('beforeend', lineTemplate(id));
        const element = lines.lastElementChild;
        element.querySelector('[data-id="line-fetch"]').addEventListener('click', () => fetchLine(element));
        return element;
    }

    function specsOf(choice) {
        const chosen = choice.chosen || {};
        const options = choice.product?.options || [];
        const parts = options.filter((o) => chosen[o.name]).map((o) => `${o.label}: ${chosen[o.name]}`);
        if (choice.withBrand && choice.product?.brand) parts.push(`برند: ${choice.product.brand}`);
        return parts.join('، ');
    }

    async function applyChoice(element, choice) {
        if (!element) return;
        element.querySelector('.line-url').value = choice.product?.url || '';
        const result = element.querySelector('.line-result');
        result.innerHTML = `<div class="row"><div class="thumb photo"></div><div class="row-main"><div class="row-title"></div><div class="row-sub"></div></div><div class="row-end qty"></div></div>`;
        result.querySelector('.row-title').textContent = choice.title;
        result.querySelector('.row-sub').textContent = specsOf(choice);
        result.querySelector('.qty').textContent = `${String(choice.quantity || 1).replace(/[0-9]/g, (d) => '۰۱۲۳۴۵۶۷۸۹'[d])} عدد`;
        dirty = true;
        publish(false);
        if (choice.image?.ref) {
            const reply = await request('product.image', { ref: choice.image.ref }, 30000);
            if (reply?.ok && reply.data) {
                result.querySelector('.photo').style.backgroundImage = `url(data:${reply.mime};base64,${reply.data})`;
            }
        }
    }

    async function take(intakeId) {
        const reply = await request('intake.take', { intakeId }, 30000);
        if (!reply?.ok) {
            status('intake-status', 'فهرست محصول ها پیدا نشد؛ دوباره از «ثبت سفارش» شروع کنید.');
            return;
        }
        for (const choice of reply.lines || []) {
            await applyChoice(addLine(), choice);
        }
        status('intake-status', `${String((reply.lines || []).length).replace(/[0-9]/g, (d) => '۰۱۲۳۴۵۶۷۸۹'[d])} محصول به سفارش اضافه شد.`);
    }

    async function fetchLine(element) {
        const url = element.querySelector('.line-url').value.trim();
        if (!/^https?:\/\//.test(url)) return;
        if (!hasFeature('intake')) return;
        const reply = await request('intake.line', { lineKey: element.dataset.line, url, product: null }, 15 * 60000);
        if (reply?.ok && reply.choice) {
            await applyChoice(element, reply.choice);
        } else if (reply?.error === 'failed') {
            element.querySelector('.line-result').textContent = 'مشخصات این کالا را در همین ردیف بنویسید و عکس را با دکمه عکس ردیف اضافه کنید.';
        }
    }

    function saveDraft() {
        try {
            localStorage.setItem(DRAFT_KEY, JSON.stringify({ at: Date.now(), path: location.pathname, note: document.querySelector('[data-id="note"]')?.value || '' }));
        } catch {
            // a blocked store only loses the draft
        }
    }

    function restoreDraft() {
        try {
            const draft = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null');
            if (draft && Date.now() - draft.at < 30 * 60000) {
                const note = document.querySelector('[data-id="note"]');
                if (note) note.value = draft.note || '';
                dirty = true;
            }
        } catch {
            // nothing to restore
        }
    }

    async function save() {
        const response = await fetch('/app/orders', { method: 'POST', credentials: 'same-origin' });
        const data = await response.json();
        try {
            localStorage.removeItem(DRAFT_KEY);
        } catch {
            // nothing kept
        }
        dirty = false;
        notify('haptic', { kind: 'success' });
        await visit(data.location);
    }

    function mount() {
        watchTitle();
        document.querySelectorAll('[data-dirty]').forEach((input) => {
            input.addEventListener('input', () => {
                if (!dirty) {
                    dirty = true;
                    publish(false);
                }
            });
        });
        const on = (id, handler) => document.querySelector(`[data-id="${id}"]`)?.addEventListener('click', handler);
        on('print', printInvoice);
        on('export', exportFile);
        on('share', () => request('share', { text: 'سفارش NR-۱۱۶۰ ثبت شد.', url: 'https://erp.trakly.info/app/orders/1160' }));
        on('save', save);
        on('add-line', () => addLine());
        on('scan', async (event) => {
            event.preventDefault();
            const reply = await request('scan', { formats: ['ean13', 'code128'] }, 300000);
            if (reply?.ok) {
                document.querySelector('[data-id="barcode"]').value = reply.code;
            } else {
                status('scan-status', reply?.error === 'unavailable' ? 'اسکن بارکد در این گوشی ممکن نیست.' : '');
            }
        });
        on('clear-data', async () => {
            const reply = await request('shopdata.clear', {}, 120000);
            status('more-status', reply?.ok ? 'داده سایت ها پاک شد.' : '');
        });
        on('logout', () => {
            notify('session.ended', {});
            try {
                localStorage.removeItem(DRAFT_KEY);
            } catch {
                // nothing kept
            }
            location.href = '/logout';
        });
        document.querySelectorAll('[data-id="appearance"] button').forEach((button) => {
            button.addEventListener('click', () => notify('appearance.set', { mode: button.dataset.mode }));
        });
        const lock = document.querySelector('[data-id="lock"]');
        if (lock) {
            lock.checked = localStorage.getItem(LOCK_KEY) === '1';
            lock.addEventListener('change', async () => {
                const wanted = lock.checked;
                const reply = await request('lock.set', { enabled: wanted }, 120000);
                if (reply?.ok) {
                    localStorage.setItem(LOCK_KEY, wanted ? '1' : '0');
                } else {
                    lock.checked = !wanted;
                }
            });
        }
        if (isOrderForm()) {
            const params = new URLSearchParams(location.search);
            if (params.get('intake')) {
                if (localStorage.getItem(DRAFT_KEY)) restoreDraft();
                take(params.get('intake'));
            } else {
                if (!params.get('blank')) restoreDraft();
                addLine();
                request('intake.pending', {}).then((reply) => {
                    if (reply?.ok && reply.choice) {
                        const element = document.querySelector(`[data-line="${reply.lineKey}"]`) || addLine(reply.lineKey);
                        applyChoice(element, reply.choice);
                    }
                });
            }
        }
    }

    // ---- start (appMode.startAppShell) ------------------------------------------------------------------------------------

    async function start() {
        if (!meta) return;
        mount();
        remember();
        if (!native || !root.hasAttribute('data-app')) return;
        native.addEventListener('message', onMessage);
        const reply = await request('hello', { path: location.pathname }, 1000);
        if (!reply || reply.ok !== true) {
            root.removeAttribute('data-app');
            return;
        }
        hello = reply;
        applyTheme(reply.appearance?.resolved);
        applyInsets(reply.insets);
        notify('config', { topology: reply.topology || 'stacks', disabled: [], min: meta.min || 0, storeUrl: null, accountKey: meta.context === 'auth' ? null : meta.accountKey });
        publish(true);
    }

    start();
})();
