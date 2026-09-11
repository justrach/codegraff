const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { externalURL, installExternalLinks } = require('./external-links.cjs');

const APP_ORIGIN = 'http://127.0.0.1:3788';

function harness(openCallback) {
  const contents = new EventEmitter();
  const opened = [];
  let popup;
  contents.setWindowOpenHandler = handler => { popup = handler; };
  installExternalLinks(contents, APP_ORIGIN, openCallback || (url => opened.push(url)));
  return {
    opened,
    navigate(url) {
      let prevented = 0;
      contents.emit('will-navigate', { preventDefault() { prevented += 1; } }, url);
      return prevented;
    },
    popup(url) { return popup({ url }); },
  };
}

const validURLs = [
  ['HTTPS document', 'https://example.com/docs?x=1#section', 'https://example.com/docs?x=1#section'],
  ['HTTP document', 'http://example.com/docs', 'http://example.com/docs'],
  ['host and scheme case', 'HTTPS://EXAMPLE.COM/docs', 'https://example.com/docs'],
  ['HTTPS default port', 'https://example.com:443', 'https://example.com/'],
  ['HTTP default port', 'http://example.com:80', 'http://example.com/'],
  ['nondefault port', 'https://example.com:8443/docs', 'https://example.com:8443/docs'],
  ['dot segments', 'https://example.com/a/../b/./c', 'https://example.com/b/c'],
  ['spaces in path', 'https://example.com/a b', 'https://example.com/a%20b'],
  ['international host', 'https://bücher.example/', 'https://xn--bcher-kva.example/'],
  ['IPv6 host', 'http://[::1]:8080/docs', 'http://[::1]:8080/docs'],
  ['at sign in path and query', 'https://example.com/@name?email=a@b', 'https://example.com/@name?email=a@b'],
  ['encoded separators remain encoded', 'https://example.com/a%2Fb?q=%23x', 'https://example.com/a%2Fb?q=%23x'],
];

const invalidURLs = [
  ['undefined', undefined],
  ['null', null],
  ['number', 42],
  ['empty string', ''],
  ['whitespace', '   '],
  ['plain text', 'not a URL'],
  ['relative path', '/settings'],
  ['relative fragment', '#section'],
  ['protocol-relative URL', '//example.com/docs'],
  ['missing host', 'https://'],
  ['invalid IPv6', 'http://[::1'],
  ['invalid port', 'https://example.com:abc/'],
  ['out-of-range port', 'https://example.com:65536/'],
  ['space in host', 'https://exa mple.com/'],
  ['bad host escape', 'https://%zz/'],
  ['JavaScript', 'javascript:alert(1)'],
  ['mixed-case JavaScript', 'JaVaScRiPt:alert(1)'],
  ['data document', 'data:text/html,<h1>hello</h1>'],
  ['local file', 'file:///etc/passwd'],
  ['email', 'mailto:person@example.com'],
  ['telephone', 'tel:+15555550100'],
  ['FTP', 'ftp://example.com/file'],
  ['WebSocket', 'wss://example.com/'],
  ['blob URL', 'blob:https://example.com/123'],
  ['blank page', 'about:blank'],
  ['custom application scheme', 'graff://settings'],
  ['username and password', 'https://user:pass@example.com/'],
  ['username only', 'https://user@example.com/'],
  ['password only', 'https://:pass@example.com/'],
  ['encoded username', 'https://%75ser@example.com/'],
  ['encoded password', 'https://:%70ass@example.com/'],
  ['credentials on app origin', `${APP_ORIGIN.replace('://', '://user:pass@')}/settings`],
];

for (const [label, raw, canonical] of validURLs) {
  test(`externalURL canonicalizes ${label}`, () => {
    assert.equal(externalURL(raw), canonical);
    assert.equal(externalURL(canonical), canonical, 'canonicalization must be idempotent');
  });
  test(`regular click dispatches ${label} once and prevents shell navigation`, () => {
    const links = harness();
    assert.equal(links.navigate(raw), 1);
    assert.deepEqual(links.opened, [canonical]);
  });
  test(`target blank dispatches ${label} once but denies the Electron popup`, () => {
    const links = harness();
    assert.deepEqual(links.popup(raw), { action: 'deny' });
    assert.deepEqual(links.opened, [canonical]);
  });
}

for (const [label, raw] of invalidURLs) {
  test(`externalURL rejects ${label}`, () => {
    assert.equal(externalURL(raw), null);
  });
  test(`regular click blocks ${label} without throwing or dispatching`, () => {
    const links = harness();
    assert.equal(links.navigate(raw), 1);
    assert.deepEqual(links.opened, []);
  });
  test(`target blank denies ${label} without dispatching`, () => {
    const links = harness();
    assert.deepEqual(links.popup(raw), { action: 'deny' });
    assert.deepEqual(links.opened, []);
  });
}

const internalURLs = [
  `${APP_ORIGIN}/`,
  `${APP_ORIGIN}/settings?tab=browser`,
  `${APP_ORIGIN}/workspace/project#file`,
  `${APP_ORIGIN}/#settings`,
  `${APP_ORIGIN}/redirect?next=https://example.com/`,
  'HTTP://127.0.0.1:3788/settings',
];
for (const url of internalURLs) {
  test(`same-origin navigation remains internal: ${url}`, () => {
    const links = harness();
    assert.equal(links.navigate(url), 0);
    assert.deepEqual(links.opened, []);
  });
  test(`same-origin popup is denied without exposing the app origin: ${url}`, () => {
    const links = harness();
    assert.deepEqual(links.popup(url), { action: 'deny' });
    assert.deepEqual(links.opened, []);
  });
}

for (const url of [
  'http://127.0.0.1:3789/settings',
  'http://127.0.0.1/settings',
  'https://127.0.0.1:3788/settings',
  'http://localhost:3788/settings',
  'http://127.0.0.1.example.com:3788/settings',
]) {
  test(`origin comparison dispatches a distinct origin: ${url}`, () => {
    const links = harness();
    assert.equal(links.navigate(url), 1);
    assert.deepEqual(links.popup(url), { action: 'deny' });
    assert.deepEqual(links.opened, [url, url]);
  });
}

for (const kind of ['navigate', 'popup']) {
  test(`${kind} contains synchronous callback throws and handles the next click`, () => {
    const opened = [];
    const links = harness(url => {
      opened.push(url);
      if (opened.length === 1) throw new Error('destination unavailable');
    });
    const expected = kind === 'navigate' ? 1 : { action: 'deny' };
    assert.deepEqual(links[kind]('https://example.com/first'), expected);
    assert.deepEqual(links[kind]('https://example.com/second'), expected);
    assert.deepEqual(opened, ['https://example.com/first', 'https://example.com/second']);
  });

  test(`${kind} consumes callback rejection and handles subsequent clicks`, async () => {
    const opened = [];
    const links = harness(url => {
      opened.push(url);
      return Promise.reject(new Error('destination unavailable'));
    });
    const expected = kind === 'navigate' ? 1 : { action: 'deny' };
    assert.deepEqual(links[kind]('https://example.com/first'), expected);
    // Cross an event-loop turn: node:test reports any unhandled rejection as a failure.
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(links[kind]('https://example.com/second'), expected);
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(opened, ['https://example.com/first', 'https://example.com/second']);
  });
}

test('the supplied callback can change destinations without reinstalling handlers', () => {
  let destination = 'system';
  const dispatched = [];
  const links = harness(url => dispatched.push({ destination, url }));
  assert.equal(links.navigate('https://example.com/first'), 1);
  destination = 'built-in';
  assert.deepEqual(links.popup('https://example.com/second'), { action: 'deny' });
  assert.deepEqual(dispatched, [
    { destination: 'system', url: 'https://example.com/first' },
    { destination: 'built-in', url: 'https://example.com/second' },
  ]);
});
