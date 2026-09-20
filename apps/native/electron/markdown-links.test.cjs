const { test } = require('node:test');
const assert = require('node:assert/strict');
const React = require('react');
const { EventEmitter } = require('node:events');
const { renderToStaticMarkup } = require('react-dom/server');
const { externalURL, installExternalLinks } = require('./external-links.cjs');

const REPORTED_URL = 'http://localhost:3090/visual-tests/radius-preview';

async function components() {
  const [{ default: Markdown }, { BrowserLinkText }, { AssistantBody, UserBubble }, { emptyTurn }] = await Promise.all([
    import('../components/primitives/Markdown.tsx'),
    import('../components/primitives/BrowserLinks.tsx'),
    import('../components/site/ChatBubbles.tsx'),
    import('../lib/graff-events.ts'),
  ]);
  return { Markdown, BrowserLinkText, AssistantBody, UserBubble, emptyTurn };
}

function hrefs(html) {
  return [...html.matchAll(/<a\b[^>]*\bhref="([^"]+)"[^>]*>/g)].map(match => match[1]);
}

test('the reported inline-code URL is a clickable browser link', async () => {
  const { Markdown } = await components();
  const html = renderToStaticMarkup(React.createElement(Markdown, { text: `Open \`${REPORTED_URL}\`.` }));
  assert.match(html, new RegExp(`<a href="${REPORTED_URL}"`));
  assert.match(html, new RegExp(`<code title="${REPORTED_URL}"`));
  assert.match(html, new RegExp(`>${REPORTED_URL}</code>`));
});

test('assistant prose autolinks bare browser destinations and formatting', async () => {
  const { Markdown } = await components();
  const html = renderToStaticMarkup(React.createElement(Markdown, {
    text: 'Visit example.com, **www.example.org/docs**, or http://localhost:3000.',
  }));
  assert.match(html, /href="https:\/\/example\.com\/"/);
  assert.match(html, /href="http:\/\/www\.example\.org\/docs"/);
  assert.match(html, /href="http:\/\/localhost:3000\/"/);
  assert.match(html, /<strong/);
});

test('explicit Markdown anchors and file-like inline code keep their meanings', async () => {
  const { Markdown } = await components();
  const html = renderToStaticMarkup(React.createElement(Markdown, {
    text: '[Docs](https://example.com/docs) and `README.md`',
    onOpenPath() {},
  }));
  assert.equal(html.match(/<a\b/g)?.length, 1);
  assert.match(html, /href="https:\/\/example\.com\/docs"/);
  assert.match(html, /title="Open README\.md"/);
});

test('raw user-message text links browser destinations without swallowing punctuation', async () => {
  const { BrowserLinkText } = await components();
  const html = renderToStaticMarkup(React.createElement(BrowserLinkText, {
    text: `Try ${REPORTED_URL} or www.example.com.`,
  }));
  assert.match(html, new RegExp(`href="${REPORTED_URL}"`));
  assert.match(html, /href="https:\/\/www\.example\.com\/"/);
  assert.match(html, /<\/a>\.$/);
});

test('real assistant and user messages route their emitted anchors through Electron safety', async () => {
  const { AssistantBody, UserBubble, emptyTurn } = await components();
  const assistant = renderToStaticMarkup(React.createElement(AssistantBody, {
    turn: { ...emptyTurn(), status: 'done', text: `Open ${REPORTED_URL}; ignore javascript:example.com.` },
    following: false,
  }));
  const user = renderToStaticMarkup(React.createElement(UserBubble, {
    text: 'Try www.example.com, not file:///tmp/example.com or image.png.',
  }));
  const destinations = [...hrefs(assistant), ...hrefs(user)];
  assert.deepEqual(destinations, [REPORTED_URL, 'https://www.example.com/']);
  assert.match(assistant, /target="_blank"/);
  assert.match(user, /target="_blank"/);
  assert.doesNotMatch(assistant, /href="javascript:/);
  assert.doesNotMatch(user, /href="file:/);
  assert.doesNotMatch(user, /href="https:\/\/image\.png/);

  const contents = new EventEmitter();
  const opened = [];
  let popup;
  contents.setWindowOpenHandler = handler => { popup = handler; };
  installExternalLinks(contents, 'http://127.0.0.1:3788', url => opened.push(url));
  for (const href of destinations) {
    assert.equal(externalURL(href), href);
    assert.deepEqual(popup({ url: href }), { action: 'deny' });
  }
  assert.deepEqual(opened, destinations);
});
