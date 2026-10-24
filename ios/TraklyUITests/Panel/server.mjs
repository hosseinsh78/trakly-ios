#!/usr/bin/env node
/**
 * The local stand-in of the Trakly panel for the iOS tests (docs/specs/phase10-apps-and-stores.md §K5, §L4).
 *
 * The public iOS mirror carries no server code (§O13 O-Q2), so the iOS CI cannot run Laravel and its `/dev/shop/*`
 * fixture shops the way android-ui.yml does. This plain Node server (no dependency) plays the panel on
 * http://127.0.0.1:8000 instead: a few pages in the panel's app mode (the web side of TNB/1 in `panel.js`: `hello`,
 * `config`, `tabs`, `page`, `ready`, `route`, `compose`, `intake.*`, `product.image`, `download`, `file.save`, `print`,
 * `share`, `scan`, `appearance.set`, `lock.set`, `shopdata.clear`, `session.ended`, and the native → web requests and
 * events), the sign-in page, a 404 page, a print view, an export, and the fixture shops the reader reads (JSON-LD
 * products, a challenge that passes by itself, a page without a product, generated photos). The real panel is proved
 * by the private repository's web tests; this proves the native side against the same contracts.
 *
 *   node ios/TraklyUITests/Panel/server.mjs [--port 8000]
 *
 * Test controls (the UI tests call them over HTTP): POST /__test/reset, /__test/min?value=<n>, /__test/down?on=1,
 * /__test/share?url=<link> and /__test/action?type=<quick action type> (picked up by a Debug build at its next
 * activation, as if the share extension or the home screen had sent them), /__test/line?url=<link> (the first line of
 * the next order form holds that link), /__test/appearance?mode=light|dark (the booted Simulator's system appearance,
 * through `xcrun simctl ui` on the CI Mac). The fixture link /dev/shop/forbidden answers the read with `permission`.
 */
import http from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const IOS = path.resolve(HERE, '..', '..');
const portIndex = process.argv.indexOf('--port');
const PORT = portIndex > 0 ? Number(process.argv[portIndex + 1]) : 8000;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const USERS = { shop1: 'password' };

const state = { sessions: new Set(), min: 0, down: false, saved: 0, landing: '/app', shares: [], actions: [], lineUrl: '', log: [] };

// ---- products of the fixture shops -----------------------------------------------------------------------------------

const img = (n) => `${ORIGIN}/dev/shop/img/${n}.png`;

function productGroup(url) {
    const colours = [['Ocean Blue', 1], ['Sand', 2]];
    const sizes = ['S', 'M', 'L'];
    const variants = [];
    for (const [colour, photo] of colours) {
        for (const size of sizes) {
            variants.push({ options: { color: colour, size }, image: img(photo), price: '49.00', sku: `ALS-${colour[0]}-${size}`, available: !(colour === 'Sand' && size === 'L') });
        }
    }
    return {
        url, site: '127.0.0.1', title: 'Aurora Linen Shirt', brand: 'Trakly Fixture Shop', images: [img(1), img(2), img(5)], price: '49.00', currency: 'USD',
        options: [{ name: 'color', label: 'رنگ', values: colours.map((c) => c[0]) }, { name: 'size', label: 'سایز', values: sizes }],
        variants,
    };
}

function manySizes(url) {
    const sizes = [];
    for (let s = 36; s <= 47.5; s += 0.5) sizes.push(String(s));
    return {
        url, site: '127.0.0.1', title: 'Cloud Runner', brand: 'Trakly Fixture Shop', images: [img(4), img(3)], price: '98.00', currency: 'USD',
        options: [{ name: 'size', label: 'سایز', values: sizes }],
        variants: sizes.map((size) => ({ options: { size }, image: null, price: null, sku: `CR-${size}`, available: size !== '42' && size !== '44.5' })),
    };
}

function serverTee(url) {
    return {
        url, site: '127.0.0.1', title: 'Linen Tee', brand: 'Acme', images: [img(3), img(6)], price: '35.00', currency: 'USD',
        options: [{ name: 'size', label: 'سایز', values: ['S', 'M', 'L', 'XL'] }],
        variants: ['S', 'M', 'L', 'XL'].map((size) => ({ options: { size }, image: null, price: null, sku: `LT-${size}`, available: true })),
    };
}

function productFor(url) {
    const pathname = new URL(url, ORIGIN).pathname;
    if (pathname === '/dev/shop/sizes') return manySizes(url);
    if (pathname === '/dev/shop/server-tee') return serverTee(url);
    if (pathname === '/dev/shop/product-group' || pathname === '/dev/shop/challenge') return productGroup(url.replace('/challenge', '/product-group').replace(/\?.*$/, ''));
    return null;
}

/** JSON-LD of a fixture page (what the reader asset extracts; its image URLs bound native's image fetches). */
function jsonLd(product) {
    return {
        '@context': 'https://schema.org',
        '@type': 'ProductGroup',
        name: product.title,
        brand: { '@type': 'Brand', name: product.brand },
        url: product.url,
        image: product.images,
        variesBy: product.options.map((o) => o.name),
        hasVariant: product.variants.map((v) => ({
            '@type': 'Product', name: `${product.title} ${Object.values(v.options).join(' ')}`, sku: v.sku, image: v.image || product.images[0],
            color: v.options.color, size: v.options.size,
            offers: { '@type': 'Offer', price: v.price || product.price, priceCurrency: product.currency, availability: v.available ? 'https://schema.org/InStock' : 'https://schema.org/OutOfStock' },
        })),
    };
}

// ---- a PNG without any library -----------------------------------------------------------------------------------------

const CRC = (() => {
    const table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        table[n] = c;
    }
    return (buffer) => {
        let c = -1;
        for (const byte of buffer) c = table[(c ^ byte) & 0xff] ^ (c >>> 8);
        return (c ^ -1) >>> 0;
    };
})();

function chunk(type, data) {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(CRC(body));
    return Buffer.concat([length, body, crc]);
}

const PALETTE = [[75, 91, 255], [214, 186, 140], [18, 183, 106], [11, 18, 48], [240, 240, 244], [247, 144, 9]];
const pngCache = new Map();

function png(n) {
    if (pngCache.has(n)) return pngCache.get(n);
    const size = 600;
    const [r, g, b] = PALETTE[(n - 1 + PALETTE.length * 10) % PALETTE.length];
    const light = [Math.min(255, r + 45), Math.min(255, g + 45), Math.min(255, b + 45)];
    const raw = Buffer.alloc((size * 3 + 1) * size);
    for (let y = 0; y < size; y++) {
        const row = y * (size * 3 + 1);
        raw[row] = 0;
        for (let x = 0; x < size; x++) {
            const dx = x - 300, dy = y - 300;
            const inside = dx * dx + dy * dy < 170 * 170;
            const colour = inside ? light : [r, g, b];
            raw.set(colour, row + 1 + x * 3);
        }
    }
    const header = Buffer.alloc(13);
    header.writeUInt32BE(size, 0);
    header.writeUInt32BE(size, 4);
    header[8] = 8; header[9] = 2; header[10] = 0; header[11] = 0; header[12] = 0;
    const file = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
    pngCache.set(n, file);
    return file;
}

// ---- pages ------------------------------------------------------------------------------------------------------------

const esc = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const fa = (text) => String(text).replace(/[0-9]/g, (d) => '۰۱۲۳۴۵۶۷۸۹'[Number(d)]);

const ORDERS = [
    { id: 1160, number: 'NR-1160', customer: 'مریم احمدی', status: 'در انتظار خرید', tone: 'warning', total: '۱۲٬۴۸۰٬۰۰۰' },
    { id: 1159, number: 'NR-1159', customer: 'سارا کریمی', status: 'خریداری شد', tone: 'info', total: '۸٬۹۰۰٬۰۰۰' },
    { id: 1158, number: 'NR-1158', customer: 'نازنین رضایی', status: 'تحویل شد', tone: 'success', total: '۳٬۲۵۰٬۰۰۰' },
    { id: 1157, number: 'NR-1157', customer: 'الهام موسوی', status: 'در راه', tone: 'brand', total: '۱۵٬۷۰۰٬۰۰۰' },
    { id: 1156, number: 'NR-1156', customer: 'فرزانه صادقی', status: 'تحویل شد', tone: 'success', total: '۶٬۴۰۰٬۰۰۰' },
];
const CUSTOMERS = [
    { id: 12, name: 'مریم احمدی', phone: '۰۹۱۲ ۳۴۵ ۶۷۸۹', orders: 7 },
    { id: 13, name: 'سارا کریمی', phone: '۰۹۳۵ ۱۱۲ ۴۴۵۶', orders: 3 },
    { id: 14, name: 'نازنین رضایی', phone: '۰۹۱۹ ۸۷۶ ۵۴۳۲', orders: 12 },
    { id: 15, name: 'الهام موسوی', phone: '۰۹۰۱ ۲۲۳ ۳۴۴۵', orders: 1 },
];

function header(title, extra = '') {
    return `<header class="page-header"><h1 data-page-title>${esc(title)}</h1>${extra}</header>`;
}

function orderCard(order) {
    return `<a class="card row link" href="/app/orders/${order.id}" data-id="order-${order.id}">
      <div class="row-main"><div class="row-title">سفارش <bdi>${esc(fa(order.number))}</bdi></div><div class="row-sub">${esc(order.customer)}</div></div>
      <div class="row-end"><span class="chip ${order.tone}">${esc(order.status)}</span><div class="amount">${order.total} <small>تومان</small></div></div>
    </a>`;
}

const PAGES = {
    '/app': () => ({
        meta: { context: 'tab', tab: 'home', title: 'خانه', refreshable: true, search: true },
        html: `${header('خانه')}
          <section class="hero"><div class="hero-label">فروش این ماه</div><div class="hero-value">۲۸۴٬۵۰۰٬۰۰۰ <small>تومان</small></div>
            <div class="dots">${Array.from({ length: 28 }, (_, i) => `<i style="--h:${18 + ((i * 37) % 52)}px"></i>`).join('')}</div></section>
          <h2 class="section">دسترسی سریع</h2>
          <div class="tiles">
            <a class="tile" href="/app/orders/create" data-id="tile-create"><span class="tile-icon"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg></span>ثبت سفارش</a>
            <a class="tile" href="/app/orders/quick" data-id="tile-quick"><span class="tile-icon"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M13 3 5 14h6l-1 7 8-11h-6z"/></svg></span>سفارش سریع</a>
            <a class="tile" href="/app/customers/create"><span class="tile-icon"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm-7 8a7 7 0 0 1 14 0"/></svg></span>مشتری تازه</a>
            <a class="tile" href="/app/products/create" data-id="tile-product"><span class="tile-icon"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7l8-4 8 4v10l-8 4-8-4zM4 7l8 4 8-4M12 11v10"/></svg></span>محصول تازه</a>
          </div>
          <h2 class="section">آخرین سفارش ها</h2>
          ${ORDERS.slice(0, 3).map(orderCard).join('')}
          <a class="card row link" href="/app/orders/999999" data-id="missing-link"><div class="row-main"><div class="row-title">یک لینک قدیمی</div><div class="row-sub">صفحه ای که دیگر نیست</div></div></a>`,
    }),
    '/app/orders': () => ({
        meta: { context: 'tab', tab: 'orders', title: 'سفارش ها', refreshable: true, search: true },
        html: `${header('سفارش ها')}
          <div class="segmented"><span class="on">همه</span><span>در انتظار خرید</span><span>در راه</span><span>تحویل شد</span></div>
          ${ORDERS.map(orderCard).join('')}`,
    }),
    '/app/customers': () => ({
        meta: { context: 'tab', tab: 'customers', title: 'مشتریان', refreshable: true, search: true },
        html: `${header('مشتریان')}
          ${CUSTOMERS.map((c) => `<a class="card row link" href="/app/customers/${c.id}"><div class="avatar">${esc(c.name[0])}</div><div class="row-main"><div class="row-title">${esc(c.name)}</div><div class="row-sub"><bdi>${c.phone}</bdi></div></div><div class="row-end">${fa(c.orders)} سفارش</div></a>`).join('')}`,
    }),
    '/app/more': () => ({
        meta: { context: 'tab', tab: 'more', title: 'بیشتر', refreshable: false, search: true },
        html: `${header('بیشتر')}
          <div class="card profile"><div class="avatar big">ش</div><div><div class="row-title">شیرین فروشگاه یک</div><div class="row-sub">مدیر فروشگاه</div></div></div>
          <h2 class="section">برنامه</h2>
          <div class="grouped">
            <div class="cell"><span>ظاهر</span><span class="seg" data-id="appearance"><button data-mode="system">سیستم</button><button data-mode="light">روشن</button><button data-mode="dark">تیره</button></span></div>
            <label class="cell"><span>قفل برنامه</span><input type="checkbox" class="switch" data-id="lock"></label>
            <button class="cell link" data-id="clear-data">پاک کردن داده سایت ها</button>
            <a class="cell link" href="/privacy">حریم خصوصی</a>
            <a class="cell link" href="/account-deletion">درخواست حذف حساب</a>
          </div>
          <div class="grouped"><button class="cell danger" data-id="logout">خروج</button></div>
          <p class="muted center" data-id="more-status"></p>`,
    }),
    '/app/orders/create': (url) => ({
        meta: { context: 'modal', tab: null, title: 'سفارش تازه', refreshable: false, search: false, form: true },
        html: orderForm('سفارش تازه', url),
    }),
    '/app/orders/quick': (url) => ({
        meta: { context: 'modal', tab: null, title: 'سفارش سریع', refreshable: false, search: false, form: true },
        html: orderForm('سفارش سریع', url),
    }),
    '/app/customers/create': () => ({
        meta: { context: 'modal', tab: null, title: 'مشتری تازه', refreshable: false, search: false, form: true },
        html: `${header('مشتری تازه')}<div class="card form"><label>نام<input name="name" data-dirty></label><label>شماره موبایل<input name="mobile" inputmode="tel" data-dirty></label></div>`,
    }),
    '/app/products/create': () => ({
        meta: { context: 'modal', tab: null, title: 'محصول تازه', refreshable: false, search: false, form: true },
        html: `${header('محصول تازه')}<div class="card form"><label>نام محصول<input name="name" data-dirty></label>
          <div class="field"><label for="barcode">بارکد</label><span class="inline"><input id="barcode" name="barcode" data-id="barcode" dir="ltr"><button type="button" class="ghost" data-id="scan">اسکن بارکد</button></span></div>
          <p class="muted" data-id="scan-status"></p></div>`,
    }),
    '/app/setup': () => ({
        meta: { context: 'standalone', tab: null, title: 'راه اندازی فروشگاه', refreshable: false, search: false, night: true },
        html: `<div class="night-scene"><div class="setup"><div class="step">مرحله ۱ از ۳</div><h1>راه اندازی فروشگاه</h1>
          <p>نام فروشگاه و واحد پول را بنویسید؛ بعدا هم می توانید آن ها را تغییر دهید.</p>
          <label>نام فروشگاه<input value="بوتیک گلبرگ"></label><label>واحد پول<input value="تومان"></label></div>
          <div class="sticky night"><button class="primary">ادامه</button></div></div>`,
    }),
};

function orderForm(title, url) {
    return `${header(title)}
      <div class="card form"><label>مشتری<input name="customer" placeholder="نام یا شماره موبایل مشتری" data-dirty data-id="customer"></label></div>
      <h2 class="section">اقلام خرید</h2>
      <div id="lines" data-prefill="${esc(state.lineUrl)}"></div>
      <button class="ghost wide" data-id="add-line">افزودن ردیف</button>
      <div class="card form"><label>یادداشت<textarea name="note" rows="3" data-dirty data-id="note"></textarea></label></div>
      <p class="muted" data-id="intake-status"></p>
      <div class="sticky"><button class="primary" data-id="save">ثبت سفارش</button></div>`;
}

function orderPage(id) {
    const order = ORDERS.find((o) => o.id === id);
    if (!order) return null;
    return {
        meta: { context: 'push', tab: 'orders', title: `سفارش ${fa(order.number)}`, refreshable: true, search: false, back: { label: 'سفارش ها' }, action: { id: 'print', icon: 'print', label: 'چاپ فاکتور' } },
        html: `${header(`سفارش ${fa(order.number)}`, `<span class="chip ${order.tone}">${esc(order.status)}</span>`)}
          <div class="card"><div class="kv"><span>مشتری</span><b>${esc(order.customer)}</b></div><div class="kv"><span>جمع</span><b>${order.total} تومان</b></div></div>
          <h2 class="section">اقلام</h2>
          <div class="card line"><div class="thumb" style="background:#4B5BFF"></div><div class="row-main"><div class="row-title">پیراهن کتان</div><div class="row-sub">رنگ: <bdi>Ocean Blue</bdi>، سایز: <bdi>M</bdi></div></div><div class="row-end">${fa(2)} عدد</div></div>
          <div class="card line"><div class="thumb" style="background:#12B76A"></div><div class="row-main"><div class="row-title">کیف دستی چرم</div><div class="row-sub">رنگ: قهوه ای</div></div><div class="row-end">${fa(1)} عدد</div></div>
          <div class="actions">
            <button class="ghost" data-id="print">چاپ فاکتور</button>
            <button class="ghost" data-id="export">دریافت اکسل</button>
            <button class="ghost" data-id="share">اشتراک گذاری</button>
            <a class="ghost" href="/app/orders/${id}/edit" data-id="edit">ویرایش سفارش</a>
          </div>`,
    };
}

function customerPage(id) {
    const customer = CUSTOMERS.find((c) => c.id === id);
    if (!customer) return null;
    return {
        meta: { context: 'push', tab: 'customers', title: customer.name, refreshable: true, search: false, back: { label: 'مشتریان' } },
        html: `${header(customer.name)}<div class="card"><div class="kv"><span>موبایل</span><b><bdi>${customer.phone}</bdi></b></div><div class="kv"><span>سفارش ها</span><b>${fa(customer.orders)}</b></div></div>`,
    };
}

function resolvePage(pathname, url) {
    if (PAGES[pathname]) return PAGES[pathname](url);
    let match = /^\/app\/orders\/(\d+)$/.exec(pathname);
    if (match) return orderPage(Number(match[1]));
    match = /^\/app\/orders\/(\d+)\/edit$/.exec(pathname);
    if (match && ORDERS.some((o) => o.id === Number(match[1]))) {
        return { meta: { context: 'modal', tab: null, title: 'ویرایش سفارش', refreshable: false, search: false, form: true }, html: orderForm('ویرایش سفارش', url) };
    }
    match = /^\/app\/customers\/(\d+)$/.exec(pathname);
    if (match) return customerPage(Number(match[1]));
    return null;
}

const TABS = {
    items: [
        { key: 'home', label: 'خانه', badge: null },
        { key: 'orders', label: 'سفارش ها', badge: 3 },
        { key: 'customers', label: 'مشتریان', badge: null },
        { key: 'more', label: 'بیشتر', badge: null },
    ],
    create: false,
    quick: true,
};

function document(meta, html, { app, status = 200 } = {}) {
    const full = { ...meta, min: state.min, accountKey: 'a1b2c3d4e5f60718293a4b5c6d7e8f90', tabs: TABS };
    const appAttributes = app ? ' data-app-client="ios" data-app-store="dev" data-app="ios"' : '';
    return {
        status,
        type: 'text/html; charset=utf-8',
        body: `<!doctype html>
<html lang="fa" dir="rtl"${appAttributes}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(meta.title)}</title>
<link rel="stylesheet" href="/panel.css">
<script id="trakly-page" type="application/json">${JSON.stringify(full).replace(/</g, '\\u003c')}</script>
<script src="/panel.js" defer></script>
</head>
<body class="ctx-${meta.context}${meta.night ? ' night' : ''}"><main id="main">${html}</main></body>
</html>`,
    };
}

function loginPage(app, error) {
    return document(
        { context: 'auth', tab: null, title: 'ورود', refreshable: false, search: false, night: true },
        `<div class="night-scene"><div class="aurora"></div><form class="glass" method="post" action="/login" data-id="login-form">
          <div class="brand">Trakly</div><h1>ورود به پنل</h1>
          <p class="muted-night">حساب کاربری را مدیر فروشگاه یا پشتیبانی Trakly می سازد.</p>
          ${error ? `<p class="error">نام کاربری یا رمز عبور درست نیست.</p>` : ''}
          <label>نام کاربری<input name="username" autocomplete="username" dir="ltr" data-id="username"></label>
          <label>رمز عبور<input name="password" type="password" autocomplete="current-password" dir="ltr" data-id="password"></label>
          <button class="primary" type="submit" data-id="sign-in">ورود</button>
          <footer><a href="/privacy">حریم خصوصی</a><a href="/account-deletion">حذف حساب</a></footer>
        </form></div>`,
        { app },
    );
}

function errorPage(status) {
    return {
        status,
        type: 'text/html; charset=utf-8',
        body: `<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>صفحه پیدا نشد</title><link rel="stylesheet" href="/panel.css"><script>if (matchMedia('(prefers-color-scheme: dark)').matches) document.documentElement.classList.add('dark');</script></head>
<body class="error-page"><main><div class="error-code">${fa(status)}</div><h1>این صفحه پیدا نشد</h1><p>لینکی که باز کردید دیگر وجود ندارد یا جابجا شده است.</p><a class="primary" href="/app">بازگشت به خانه</a></main></body></html>`,
    };
}

function shopPage(kind, query) {
    if (kind === 'img') return null;
    if (kind === 'challenge' && query.get('passed') !== '1') {
        const after = Math.max(0, Math.min(120000, Number(query.get('after') || '6000')));
        return {
            status: 200,
            type: 'text/html; charset=utf-8',
            body: `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Just a moment...</title></head>
<body style="font-family:-apple-system;padding:40px;text-align:center"><div id="challenge-running"><h2>Checking your browser before accessing the shop</h2><p>This takes a few seconds.</p></div>
<script>setTimeout(function(){location.replace(location.pathname + '?passed=1')}, ${after});</script></body></html>`,
        };
    }
    if (kind === 'plain') {
        return { status: 200, type: 'text/html; charset=utf-8', body: `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Fixture shop</title></head><body style="font-family:-apple-system;padding:24px"><h1>Welcome to the fixture shop</h1><p>Our new collection is coming soon.</p></body></html>` };
    }
    const product = productFor(`${ORIGIN}/dev/shop/${kind}`);
    if (!product) return null;
    return {
        status: 200,
        type: 'text/html; charset=utf-8',
        body: `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(product.title)} | Fixture shop</title>
<meta property="og:type" content="product"><meta property="og:title" content="${esc(product.title)}"><meta property="og:image" content="${product.images[0]}">
<script type="application/ld+json">${JSON.stringify(jsonLd(product))}</script>
<style>body{font-family:-apple-system;margin:0;background:#fafafa;color:#111}.hero{display:block;width:100%;aspect-ratio:1;background:#ddd}h1{font-size:24px;margin:16px}p{margin:0 16px 12px;color:#555}.price{font-weight:700;font-size:20px;margin:0 16px}.sizes{display:flex;flex-wrap:wrap;gap:8px;margin:16px}.sizes span{border:1px solid #ccc;border-radius:8px;padding:8px 12px}</style></head>
<body><img class="hero" src="${product.images[0]}" alt=""><h1>${esc(product.title)}</h1><p>${esc(product.brand)}</p><div class="price">$${product.price}</div>
<div class="sizes">${product.options[product.options.length - 1].values.map((v) => `<span>${esc(v)}</span>`).join('')}</div></body></html>`,
    };
}

function printPage() {
    return {
        status: 200,
        type: 'text/html; charset=utf-8',
        body: `<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>فاکتور NR-1160</title><link rel="stylesheet" href="/panel.css"></head>
<body class="print"><main><h1>فاکتور فروش</h1><div class="kv"><span>شماره</span><b><bdi>NR-۱۱۶۰</bdi></b></div><div class="kv"><span>مشتری</span><b>مریم احمدی</b></div>
<table><thead><tr><th>شرح کالا</th><th>تعداد</th><th>مبلغ</th></tr></thead><tbody><tr><td>پیراهن کتان</td><td>۲</td><td>۸٬۴۰۰٬۰۰۰</td></tr><tr><td>کیف دستی چرم</td><td>۱</td><td>۴٬۰۸۰٬۰۰۰</td></tr></tbody>
<tfoot><tr><td>جمع</td><td></td><td>۱۲٬۴۸۰٬۰۰۰ تومان</td></tr></tfoot></table></main></body></html>`,
    };
}

function publicPage(title, text) {
    return {
        status: 200,
        type: 'text/html; charset=utf-8',
        body: `<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title><link rel="stylesheet" href="/panel.css"></head><body class="public"><main><h1>${esc(title)}</h1><p>${esc(text)}</p></main></body></html>`,
    };
}

const BRIDGE_TEST = `<!doctype html><html><head><meta charset="utf-8"><title>bridge</title></head><body>
<iframe src="http://localhost:${PORT}/test/frame"></iframe>
<script>
var results = [];
function note(text) { results.push(text); document.title = results.join(' '); }
var N = window.TraklyNative;
if (!N) { note('no-bridge'); } else {
  N.addEventListener('message', function (event) {
    var m = JSON.parse(event.data);
    if (m.re === 'w_hello_0001') note('hello:' + (m.ok ? 'ok' : m.error));
    if (m.re === 'w_lock_00001') note('lock:' + (m.ok ? 'ok' : m.error));
    if (m.re === 'w_spoof_0001') note('spoof:' + (m.ok ? 'ok' : m.error));
  });
  N.postMessage(JSON.stringify({ v: 1, id: 'w_hello_0001', type: 'hello', path: location.pathname }));
  setTimeout(function () {
    history.pushState({}, '', '/app/more');
    N.postMessage(JSON.stringify({ v: 1, id: 'w_lock_00001', type: 'lock.set', enabled: false }));
  }, 400);
}
</script></body></html>`;

const FRAME_TEST = `<!doctype html><html><head><meta charset="utf-8"></head><body><script>
try { window.parent.TraklyNative && window.parent.TraklyNative.postMessage('{}'); } catch (e) {}
if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.trakly) {
  window.webkit.messageHandlers.trakly.postMessage(JSON.stringify({ v: 1, id: 'w_frame_0001', type: 'hello', path: '/app' }));
}
</script></body></html>`;

// ---- the server -------------------------------------------------------------------------------------------------------

function cookieOf(request) {
    const match = /(?:^|;\s*)trakly_session=([A-Za-z0-9_-]+)/.exec(request.headers.cookie || '');
    return match ? match[1] : null;
}

function signedIn(request) {
    const token = cookieOf(request);
    return token !== null && state.sessions.has(token);
}

function readBody(request) {
    return new Promise((resolve) => {
        const parts = [];
        request.on('data', (part) => parts.push(part));
        request.on('end', () => resolve(Buffer.concat(parts).toString('utf8')));
    });
}

function send(response, { status = 200, type = 'text/plain; charset=utf-8', body = '', headers = {} }) {
    response.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
    response.end(body);
}

const ASSETS = {
    '/panel.js': ['application/javascript; charset=utf-8', path.join(HERE, 'panel.js')],
    '/panel.css': ['text/css; charset=utf-8', path.join(HERE, 'panel.css')],
    '/fonts/Vazirmatn-Regular.ttf': ['font/ttf', path.join(IOS, 'Trakly', 'Resources', 'Fonts', 'Vazirmatn-Regular.ttf')],
    '/fonts/Vazirmatn-Bold.ttf': ['font/ttf', path.join(IOS, 'Trakly', 'Resources', 'Fonts', 'Vazirmatn-Bold.ttf')],
};

const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, ORIGIN);
    const pathname = url.pathname;
    const app = /\bTraklyApp\/\d+\.\d+\.\d+ \(ios; \d+; (?:appstore|dev)\)/.test(request.headers['user-agent'] || '');
    const visit = request.headers['x-trakly-visit'] === '1';

    // The request log a failed UI test attaches (`/__test/log`): what the app asked and whether it was signed in.
    if (!pathname.startsWith('/__test/') && !pathname.startsWith('/fonts/') && pathname !== '/health') {
        state.log.push(`${new Date().toISOString().slice(11, 23)} ${request.method} ${pathname}${url.search}${visit ? ' visit' : ''} cookie=${cookieOf(request) ? 'yes' : 'no'} signed=${signedIn(request) ? 'yes' : 'no'}`);
        if (state.log.length > 300) state.log.splice(0, state.log.length - 300);
    }

    if (state.down && !pathname.startsWith('/__test/') && pathname !== '/health') {
        request.socket.destroy();
        return;
    }

    try {
        if (pathname === '/health') return send(response, { body: 'ok' });
        if (pathname === '/__test/reset') {
            state.sessions.clear();
            state.min = 0;
            state.down = false;
            state.landing = '/app';
            state.shares = [];
            state.actions = [];
            state.lineUrl = '';
            state.log = [];
            return send(response, { body: 'reset' });
        }
        if (pathname === '/__test/log') {
            return send(response, { body: state.log.join(String.fromCharCode(10)) });
        }
        if (pathname === '/__test/min') {
            state.min = Number(url.searchParams.get('value') || '0');
            return send(response, { body: `min ${state.min}` });
        }
        if (pathname === '/__test/landing') {
            state.landing = url.searchParams.get('path') || '/app';
            return send(response, { body: 'landing ' + state.landing });
        }
        if (pathname === '/__test/share') {
            state.shares.push(url.searchParams.get('url') || '');
            return send(response, { body: 'queued' });
        }
        if (pathname === '/__test/share-queue') {
            const queued = state.shares.filter(Boolean);
            state.shares = [];
            return send(response, { type: 'application/json', body: JSON.stringify(queued) });
        }
        if (pathname === '/__test/appearance') {
            const mode = url.searchParams.get('mode') === 'dark' ? 'dark' : 'light';
            execFile('xcrun', ['simctl', 'ui', 'booted', 'appearance', mode], (error) => {
                send(response, { status: error ? 500 : 200, body: error ? String(error) : 'appearance ' + mode });
            });
            return;
        }
        if (pathname === '/__test/line') {
            state.lineUrl = url.searchParams.get('url') || '';
            return send(response, { body: 'line ' + state.lineUrl });
        }
        if (pathname === '/__test/action') {
            state.actions.push(url.searchParams.get('type') || '');
            return send(response, { body: 'queued' });
        }
        if (pathname === '/__test/action-queue') {
            const queued = state.actions.filter(Boolean);
            state.actions = [];
            return send(response, { type: 'application/json', body: JSON.stringify(queued) });
        }
        if (pathname === '/__test/down') {
            state.down = url.searchParams.get('on') === '1';
            return send(response, { body: `down ${state.down}` });
        }
        if (ASSETS[pathname]) {
            const [type, file] = ASSETS[pathname];
            return send(response, { type, body: readFileSync(file) });
        }
        // A panel path (the navigation policy keeps only panel paths in a panel WebView), served without a session.
        if (pathname === '/app/__test/bridge') return send(response, { type: 'text/html; charset=utf-8', body: BRIDGE_TEST });
        if (pathname === '/test/frame') return send(response, { type: 'text/html; charset=utf-8', body: FRAME_TEST });

        const shop = /^\/dev\/shop\/([a-z-]+)$/.exec(pathname);
        if (shop) {
            const page = shopPage(shop[1], url.searchParams);
            return page ? send(response, page) : send(response, { status: 404, body: 'not found' });
        }
        const image = /^\/dev\/shop\/img\/(\d+)\.png$/.exec(pathname);
        if (image) return send(response, { type: 'image/png', body: png(Number(image[1])) });
        if (pathname === '/dev/shop/not-an-image.png') return send(response, { type: 'image/png', body: 'GIF89a but not really an image' });

        if (pathname === '/privacy') return send(response, publicPage('حریم خصوصی', 'Trakly فقط اطلاعاتی را نگه می دارد که برای کار فروشگاه لازم است.'));
        if (pathname === '/account-deletion') return send(response, publicPage('حذف حساب Trakly', 'درخواست حذف حساب حداکثر تا ۳۰ روز انجام می شود.'));

        if (pathname === '/login' && request.method === 'POST') {
            const form = new URLSearchParams(await readBody(request));
            if (USERS[form.get('username')] && USERS[form.get('username')] === form.get('password')) {
                const token = crypto.randomBytes(16).toString('hex');
                state.sessions.add(token);
                return send(response, { status: 302, headers: { Location: state.landing, 'Set-Cookie': `trakly_session=${token}; Path=/; HttpOnly; SameSite=Lax` } });
            }
            return send(response, loginPage(app, true));
        }
        if (pathname === '/login') {
            return signedIn(request) ? send(response, { status: 302, headers: { Location: '/app' } }) : send(response, loginPage(app, false));
        }
        if (pathname === '/logout') {
            state.sessions.delete(cookieOf(request));
            return send(response, { status: 302, headers: { Location: '/login', 'Set-Cookie': 'trakly_session=; Path=/; Max-Age=0' } });
        }
        if (pathname === '/') return send(response, { status: 302, headers: { Location: '/app' } });

        if (pathname.startsWith('/app')) {
            if (!signedIn(request)) {
                return visit ? send(response, { status: 409, type: 'application/json', body: JSON.stringify({ location: '/login' }) }) : send(response, { status: 302, headers: { Location: '/login' } });
            }
            if (pathname === '/app/orders/product-link' && request.method === 'POST') {
                const body = JSON.parse((await readBody(request)) || '{}');
                const target = typeof body.url === 'string' ? body.url : '';
                // The server's own read succeeds only for the server-tee fixture; every other fixture shop "blocks" it,
                // so the app reads it with its reader and posts the capture (§A2 F1).
                if (new URL(target, ORIGIN).pathname === '/dev/shop/forbidden') {
                    return send(response, { type: 'application/json', body: JSON.stringify({ ok: false, reason: 'permission', message: '' }) });
                }
                const serverRead = !body.capture && new URL(target, ORIGIN).pathname === '/dev/shop/server-tee';
                const captured = typeof body.capture === 'string' && body.capture.includes('"ld"');
                const product = serverRead || captured ? productFor(target) : null;
                const failure = body.capture ? { ok: false, reason: 'not_product', message: 'در این صفحه اطلاعات محصول پیدا نشد.' } : { ok: false, reason: 'blocked', message: 'این سایت به سرور Trakly اجازه خواندن نمی دهد.' };
                return send(response, { type: 'application/json', body: JSON.stringify(product ? { ok: true, product } : failure) });
            }
            if (pathname === '/app/orders/export') {
                const rows = ['شماره,مشتری,جمع', ...ORDERS.map((o) => `${o.number},${o.customer},${o.total}`)];
                return send(response, { type: 'text/csv; charset=utf-8', body: '\ufeff' + rows.join('\n'), headers: { 'Content-Disposition': "attachment; filename=\"orders.csv\"; filename*=UTF-8''orders.csv" } });
            }
            if (/^\/app\/orders\/print\/invoices$/.test(pathname)) return send(response, printPage());
            if (pathname === '/app/orders' && request.method === 'POST') {
                state.saved++;
                return send(response, { type: 'application/json', body: JSON.stringify({ location: '/app/orders/1160' }) });
            }
            const page = resolvePage(pathname, url.href);
            if (!page) {
                return visit ? send(response, { status: 404, type: 'application/json', body: JSON.stringify({ status: 404 }) }) : send(response, errorPage(404));
            }
            if (visit) {
                return send(response, { type: 'application/json', body: JSON.stringify({ meta: { ...page.meta, min: state.min, accountKey: 'a1b2c3d4e5f60718293a4b5c6d7e8f90', tabs: TABS }, html: page.html, url: url.pathname + url.search }) });
            }
            return send(response, document(page.meta, page.html, { app }));
        }
        return send(response, errorPage(404));
    } catch (error) {
        console.error(error);
        return send(response, { status: 500, body: 'error' });
    }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`panel stand-in on ${ORIGIN}${existsSync(path.join(HERE, 'panel.js')) ? '' : ' (panel.js missing)'}`);
});
