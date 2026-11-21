(() => {
  const viewers = new Map();
  const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));

  function highlight(line) {
    const key = line.match(/^(\s*(?:-\s+)?)([\w.-]+:)(.*)$/);
    let result = key ? escape(key[1]) + `<span class="yaml-key">${escape(key[2])}</span>` : '';
    const value = key ? key[3] : line;
    const tokens = /"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|(?:^|\s)#.*$|\b(?:true|false|null|\d+)\b|\$\{[^}]+\}/g;
    let start = 0;
    for (const match of value.matchAll(tokens)) {
      result += escape(value.slice(start, match.index));
      const token = match[0];
      const kind = token.trimStart().startsWith('#') ? 'comment' : 'value';
      result += `<span class="yaml-${kind}">${escape(token)}</span>`;
      start = match.index + token.length;
    }
    return result + escape(value.slice(start));
  }

  function renderYaml(text) {
    const lines = text.split('\n');
    const indent = line => line.match(/^ */)[0].length;
    const row = i => `<span class="yaml-line"><span class="yaml-number">${i + 1}</span><code>${highlight(lines[i])}</code></span>`;
    const range = (first, end) => {
      let html = '';
      for (let i = first; i < end; i++) {
        if (lines[i].trimStart().startsWith('#')) {
          let stop = i + 1;
          while (stop < end && (!lines[stop].trim() || lines[stop].trimStart().startsWith('#'))) stop++;
          if (stop - i > 2) {
            html += `<details class="yaml-block yaml-comments" data-line="${i}"><summary>${row(i)}</summary>`;
            for (let line = i + 1; line < stop; line++) html += `<div>${row(line)}</div>`;
            html += '</details>';
            i = stop - 1;
            continue;
          }
        }
        let next = i + 1;
        while (next < end && !lines[next].trim()) next++;
        if (lines[i].trim() && next < end && indent(lines[next]) > indent(lines[i])) {
          let stop = next + 1;
          while (stop < end && (!lines[stop].trim() || indent(lines[stop]) > indent(lines[i]))) stop++;
          html += `<details class="yaml-block" data-line="${i}"${indent(lines[i]) === 0 ? ' open' : ''}><summary>${row(i)}</summary>${range(i + 1, stop)}</details>`;
          i = stop - 1;
        } else html += `<div>${row(i)}</div>`;
      }
      return html;
    };
    return range(0, lines.length);
  }

  function html(run) {
    const c = run.compose;
    if (!c) return '<div class="compose-unavailable">Compose asset has not been collected yet.</div>';
    const expected = `runs/${encodeURIComponent(run.run_id)}/docker-compose.yaml`;
    if (c.status !== 'available' || c.url !== expected || c.internal_network !== true ||
        !/^[0-9a-f]{40}$/i.test(c.commit || '') ||
        !/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/blob\/[0-9a-f]{40}\//i.test(c.source_url || '')) {
      const message = c.reason === 'missing_or_invalid_coordinates' ? 'Test description has no usable pinned Compose source.' :
        c.reason === 'publication_refused' ? 'Compose source cannot be published under the dashboard’s publication rules.' :
        'Compose source is not available at this test revision.';
      return `<details class="compose-viewer"><summary>Docker Compose <span class="ignored">unavailable</span></summary><p>${message}</p></details>`;
    }
    return `<details class="compose-viewer" data-asset-url="${escape(expected)}">
      <summary>Docker Compose <span class="ignored">Local · INTERNAL_NETWORK=true</span></summary>
      <div class="compose-toolbar">
        <a href="${escape(c.source_url)}" target="_blank" rel="noopener noreferrer">Source · ${escape(c.commit.slice(0, 8))}</a>
        <button type="button" data-action="expand" disabled>Expand YAML</button>
        <button type="button" data-action="fold" disabled>Fold YAML</button>
        <button type="button" data-action="copy" disabled>Copy</button>
        <a href="${escape(expected)}" download="docker-compose.yaml">Download</a>
      </div>
      <p class="compose-note">For local use. Companion files and container images are not included.</p>
      <div class="compose-message" role="status">Expand to load the configuration.</div>
      <div class="compose-code" role="region" aria-label="Docker Compose YAML" tabindex="0"></div>
    </details>`;
  }

  function mount(root) {
    root.querySelectorAll('.compose-viewer[data-asset-url]').forEach(panel => {
      const code = panel.querySelector('.compose-code');
      const message = panel.querySelector('.compose-message');
      const buttons = panel.querySelectorAll('button');
      const state = viewers.get(panel.dataset.assetUrl) || {text:null, open:false, expanded:null, top:0, left:0};
      viewers.set(panel.dataset.assetUrl, state);
      let loading = false;
      const display = () => {
        code.innerHTML = renderYaml(state.text);
        if (state.expanded !== null) code.querySelectorAll('.yaml-block').forEach(block => block.open = state.expanded.has(block.dataset.line));
        code.scrollTop = state.top;
        code.scrollLeft = state.left;
        buttons.forEach(button => button.disabled = false);
        message.textContent = '';
      };
      panel.open = state.open;
      if (state.text !== null) display();
      const load = async () => {
        if (!panel.open || state.text !== null || loading) return;
        loading = true;
        message.textContent = 'Loading Compose…';
        try {
          const response = await fetch(panel.dataset.assetUrl);
          if (!response.ok) throw new Error('unavailable');
          const fetched = await response.text();
          if (fetched.length > 1048576) throw new Error('too large');
          state.text = fetched;
          display();
        } catch {
          message.textContent = 'Could not load Compose. Close and reopen this section to retry.';
        } finally { loading = false; }
      };
      panel.addEventListener('toggle', event => {
        if (event.target === panel) {
          state.open = panel.open;
          load();
        } else {
          state.expanded = new Set([...code.querySelectorAll('.yaml-block[open]')].map(block => block.dataset.line));
        }
      }, true);
      code.addEventListener('scroll', () => {state.top = code.scrollTop; state.left = code.scrollLeft;});
      buttons.forEach(button => button.addEventListener('click', async () => {
        if (state.text === null) return;
        if (button.dataset.action === 'copy') {
          try {
            await navigator.clipboard.writeText(state.text);
            message.textContent = 'Compose copied.';
          } catch { message.textContent = 'Copy is unavailable in this browser. Use Download.'; }
        } else {
          code.querySelectorAll('.yaml-block').forEach(block => block.open = button.dataset.action === 'expand');
        }
      }));
    });
  }
  globalThis.ComposeViewer = {html, mount, renderYaml};
})();
