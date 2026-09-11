const assert = require('node:assert/strict');
async function runBrowserAddress({ wc, browser, destination, guard, wait }) {
  const js = code => wc.executeJavaScript(code);
  const searches = [];
  const safe = guard(destination);
  // Redirect only the expected search URL to local HTML before any network I/O.
  const query = 'how to center a div 世界';
  const expected = `https://www.google.com/search?q=${encodeURIComponent(query)}`;
  browser.session.webRequest.onBeforeRequest((details, callback) => {
    if (details.url === expected) { searches.push(details.url); callback({ redirectURL: destination }); }
    else safe(details, callback);
  });
  await js(`document.querySelector('[aria-label="Browser"]').click()`);
  await wait(`!!document.querySelector('input[aria-label="Address"]')`);
  await js('new Promise(resolve=>setTimeout(resolve,200))'); // Let the restored address arrive before editing it.
  const submit = async text => {
    await js(`(()=>{const e=document.querySelector('input[aria-label="Address"]');e.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,${JSON.stringify(text)});e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await wait(`document.querySelector('input[aria-label="Address"]').value===${JSON.stringify(text)}`);
    await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))');
    await js(`document.querySelector('input[aria-label="Address"]').form.requestSubmit()`);
  };
  await submit(query);
  await wait(() => searches.length === 1, 'ordinary words reach the search URL');
  await wait(() => {
    const page = browser.tabs.get(browser.visible)?.view?.webContents;
    return page && !page.isLoading() && page.getURL() === destination + '/';
  }, 'search fixture finished loading');
  // Navigation completion publishes several info updates and the open result.
  // Let the address consume those before editing it for the rejection case.
  await wait(`(()=>{const address=document.querySelector('input[aria-label="Address"]');return address.value===${JSON.stringify(destination + '/')} && address.closest('aside').querySelector('header')?.textContent.includes('Link destination fixture')})()`);
  await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  assert.deepEqual(searches, [expected]);
  assert.equal(await js(`!!document.querySelector('aside [role="alert"]')`), false, 'Search terms do not show Invalid URL');
  // Check scheme rejection in the real IPC path without treating it as a search.
  const oldURL = browser.tabs.get(browser.visible).view.webContents.getURL();
  await submit('javascript:alert(1)');
  await wait(`document.querySelector('aside [role="alert"]')?.textContent.includes('Only HTTP and HTTPS')`);
  assert.equal(browser.tabs.get(browser.visible).view.webContents.getURL(), oldURL);
  assert.equal(searches.length, 1);
  await js(`document.querySelector('[aria-label="Close browser"]').click()`);
  console.log('#823 browser address passed: ordinary Unicode search through real preload/IPC/navigation, no Invalid URL, unsafe scheme rejected.');
}
module.exports = { runBrowserAddress };
