(() => {
  'use strict';

  const handler = window.webkit?.messageHandlers?.kiln;
  const attributeSnapshots = new Map();
  const editingHosts = new Set();
  const structuralChanges = new Map();
  const stylesheetMetadata = new WeakMap();
  const stylesheetElements = new Map();
  let changeSequence = 0;
  let stylesheetSequence = 0;
  let overrideStyle = null;
  const headings = () => Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6'));
  let editing = false;
  let styleElement = null;
  let changeTimer = 0;

  function rememberAttribute(element, name) {
    let attributes = attributeSnapshots.get(element);
    if (!attributes) {
      attributes = new Map();
      attributeSnapshots.set(element, attributes);
    }
    if (!attributes.has(name)) attributes.set(name, element.getAttribute(name));
  }

  function setOwnedAttribute(element, name, value) {
    rememberAttribute(element, name);
    element.setAttribute(name, value);
  }

  function hasMeaningfulDirectText(element) {
    return Array.from(element.childNodes).some(node =>
      node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0
    );
  }

  function editingCandidates() {
    const selectors = 'p, h1, h2, h3, h4, h5, h6, blockquote, pre, figcaption, td, th, ul, ol, address, dt, dd';
    const candidates = Array.from(document.body?.querySelectorAll(selectors) ?? []);
    for (const element of document.body?.querySelectorAll('div, section, article, span, button') ?? []) {
      if (hasMeaningfulDirectText(element)) candidates.push(element);
    }

    // Lists take precedence over their item contents so WebKit owns list Enter behavior.
    const eligible = candidates.filter(element => {
      const isList = element.tagName === 'UL' || element.tagName === 'OL';
      if (isList && element.parentElement?.closest('ul, ol')) return false;
      if (!isList && element.closest('ul, ol')) return false;
      if (element.matches('span, button') &&
          candidates.some(candidate => candidate !== element && candidate.contains(element))) return false;
      return true;
    });
    const candidateSet = new Set(eligible);
    return eligible.filter(element => {
      // Prefer leaf blocks (for example, a paragraph inside a blockquote).
      for (const descendant of element.querySelectorAll('*')) {
        if (candidateSet.has(descendant)) return false;
      }
      return true;
    });
  }

  function addEditingStyle() {
    if (styleElement?.isConnected) return;
    styleElement = document.createElement('style');
    styleElement.setAttribute('data-kiln-editor-style', '');
    styleElement.textContent = `
      [data-kiln-editing="true"]:hover { outline: 1px solid rgba(91, 123, 103, .28); outline-offset: 2px; }
      [data-kiln-editing="true"]:focus { outline: 2px solid rgba(91, 123, 103, .52); outline-offset: 2px; }
      [data-kiln-editing="true"] { caret-color: #4d705b; }
    `;
    (document.head ?? document.documentElement).appendChild(styleElement);
  }

  function disablePageEditing() {
    for (const element of document.querySelectorAll('[contenteditable]')) {
      setOwnedAttribute(element, 'contenteditable', 'false');
    }
    for (const host of editingHosts) {
      setOwnedAttribute(host, 'contenteditable', 'false');
      setOwnedAttribute(host, 'data-kiln-editing', 'false');
    }
    editingHosts.clear();
    styleElement?.remove();
    styleElement = null;
  }

  function setEditing(enabled) {
    editing = Boolean(enabled);
    disablePageEditing();
    if (!editing) return;

    addEditingStyle();
    for (const host of editingCandidates()) {
      setOwnedAttribute(host, 'contenteditable', 'true');
      setOwnedAttribute(host, 'data-kiln-editing', 'true');
      for (const child of host.querySelectorAll('[contenteditable]')) {
        const saved = attributeSnapshots.get(child);
        if (!saved?.has('contenteditable')) continue;
        const original = saved.get('contenteditable');
        if (original === null) child.removeAttribute('contenteditable');
        else child.setAttribute('contenteditable', original);
      }
      editingHosts.add(host);
    }
  }

  function wordCount() {
    const text = document.body?.innerText ?? document.body?.textContent ?? '';
    const words = text.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu);
    return words?.length ?? 0;
  }

  function outline() {
    return headings().map((heading, index) => ({
      index,
      text: heading.innerText.trim().replace(/\s+/g, ' '),
      level: Number(heading.tagName.slice(1))
    }));
  }

  function notify(type, includeOutline = false) {
    if (!handler) return;
    const message = { type, wordCount: wordCount() };
    if (includeOutline) message.outline = outline();
    handler.postMessage(message);
  }

  function scheduleChange() {
    window.clearTimeout(changeTimer);
    changeTimer = window.setTimeout(() => notify('change', true), 80);
  }

  function cloneNodeMap(source, copy, map) {
    map.set(source, copy);
    const sourceChildren = source.childNodes;
    const copyChildren = copy.childNodes;
    for (let index = 0; index < sourceChildren.length; index += 1) {
      cloneNodeMap(sourceChildren[index], copyChildren[index], map);
    }
  }

  function serialize() {
    const clone = document.cloneNode(true);
    const cloneByOriginal = new Map();
    cloneNodeMap(document, clone, cloneByOriginal);
    for (const [element, attributes] of attributeSnapshots) {
      const copy = cloneByOriginal.get(element);
      if (!(copy instanceof Element)) continue;
      for (const [name, value] of attributes) {
        if (value === null) copy.removeAttribute(name);
        else copy.setAttribute(name, value);
      }
    }
    const clonedStyle = styleElement && cloneByOriginal.get(styleElement);
    clonedStyle?.parentNode?.removeChild(clonedStyle);
    for (const style of clone.querySelectorAll('style')) {
      style.textContent = escapeStyleText(style.textContent);
    }
    // HTML raw-text elements (script/style) must not receive XML escaping.
    const serializer = new XMLSerializer();
    return Array.from(clone.childNodes, node => node.nodeType === Node.ELEMENT_NODE
      ? node.outerHTML
      : serializer.serializeToString(node)).join('');
  }

  function escapeStyleText(css) {
    return css.replace(/<(?=\/style)/gi, '\\3C ');
  }

  function stylesheetInfo(style) {
    let info = stylesheetMetadata.get(style);
    if (!info) {
      const id = `style-${++stylesheetSequence}`;
      info = { id, label: style.getAttribute('title') || style.id || `Embedded stylesheet ${stylesheetSequence}` };
      stylesheetMetadata.set(style, info);
      stylesheetElements.set(id, style);
    }
    return info;
  }

  function stylesheets() {
    const entries = [];
    for (const style of document.querySelectorAll('style')) {
      if (style === styleElement || style === overrideStyle) continue;
      const info = stylesheetInfo(style);
      entries.push({ id: info.id, label: info.label, css: style.textContent });
    }
    entries.push({ id: 'new', label: 'New stylesheet', css: overrideStyle?.textContent ?? '' });
    return entries;
  }

  function setStylesheet(id, css) {
    if (typeof id !== 'string' || typeof css !== 'string') {
      throw new TypeError('Stylesheet id and CSS must be strings');
    }

    let target;
    if (id === 'new') {
      if (overrideStyle && css.length === 0) {
        overrideStyle.remove();
        overrideStyle = null;
        scheduleChange();
        return true;
      }
      if (!overrideStyle && css.length > 0) {
        overrideStyle = document.createElement('style');
        (document.head ?? document.documentElement).appendChild(overrideStyle);
      }
      target = overrideStyle;
    } else {
      target = stylesheetElements.get(id);
      if (!target || target === styleElement || target === overrideStyle || !document.contains(target)) {
        throw new Error(`Unknown stylesheet id: ${id}`);
      }
    }

    if (!target || target.textContent === css) return true;
    target.textContent = css;
    scheduleChange();
    return true;
  }

  function focusHeading(index) {
    const heading = headings()[Number(index)];
    if (!heading) return false;
    heading.scrollIntoView({ block: 'center', behavior: 'smooth' });
    const host = Array.from(editingHosts).find(candidate => candidate === heading || candidate.contains(heading));
    (host ?? heading).focus();
    const selection = window.getSelection();
    if (selection) {
      const range = document.createRange();
      range.selectNodeContents(heading);
      range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    return true;
  }

  function format(command, value) {
    if (!editing) return false;
    if (command === 'createLink') {
      if (typeof value !== 'string' || !value.trim()) return false;
      let url;
      try {
        url = new URL(value.trim(), document.baseURI);
      } catch {
        return false;
      }
      const relative = !/^[a-z][a-z0-9+.-]*:/i.test(value.trim()) && !value.trim().startsWith('//');
      const localRelative = relative && url.protocol === location.protocol && url.host === location.host;
      if (!localRelative && !['http:', 'https:', 'mailto:', 'tel:'].includes(url.protocol)) return false;
      return document.execCommand('createLink', false, value.trim());
    }

    const formatBlocks = {
      heading1: 'h1',
      heading2: 'h2',
      heading3: 'h3',
      paragraph: 'p'
    };
    if (Object.prototype.hasOwnProperty.call(formatBlocks, command)) {
      return changeBlock(formatBlocks[command]);
    }
    if (command === 'insertUnorderedList' || command === 'insertOrderedList') {
      return toggleList(command === 'insertUnorderedList' ? 'ul' : 'ol');
    }

    const supported = new Set(['bold', 'italic', 'underline', 'undo', 'redo']);
    if (!supported.has(command)) return false;
    return document.execCommand(command, false, null);
  }

  function recordStructuralChange(label, apply) {
    const id = ++changeSequence;
    structuralChanges.set(id, apply);
    applyStructuralChange(id, true);
    handler?.postMessage({ type: 'structuralEdit', id, label });
  }

  function applyStructuralChange(id, forward) {
    const apply = structuralChanges.get(id);
    if (!apply) return false;
    apply(forward);
    scheduleChange();
    return true;
  }

  function selectContents(element) {
    setEditing(editing);
    (element.closest('[data-kiln-editing="true"]') ?? element).focus();
    const range = document.createRange();
    range.selectNodeContents(element);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function cleanReplacement(original, tag) {
    const replacement = document.createElement(tag);
    for (const attribute of original.attributes) replacement.setAttribute(attribute.name, attribute.value);
    for (const [name, value] of attributeSnapshots.get(original) ?? []) {
      if (value === null) replacement.removeAttribute(name);
      else replacement.setAttribute(name, value);
    }
    return replacement;
  }

  function replaceContainer(original, tag, label) {
    const replacement = cleanReplacement(original, tag);
    recordStructuralChange(label, forward => {
      const from = forward ? original : replacement;
      const to = forward ? replacement : original;
      to.append(...from.childNodes);
      from.replaceWith(to);
      selectContents(to);
    });
    return true;
  }

  function changeBlock(tag) {
    const selection = getSelection();
    if (!selection?.rangeCount) return false;
    const range = selection.getRangeAt(0);
    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer : range.startContainer.parentElement;
    const original = element?.closest('p, h1, h2, h3, h4, h5, h6');
    if (!original || !original.contains(range.endContainer)) return false;
    if (original.localName === tag) return true;
    // Native formatBlock nests a heading inside a paragraph when the paragraph is
    // the editing root. Replace only the container, retaining child-node identity
    // so earlier native text edits remain undoable.
    return replaceContainer(original, tag, 'Change Paragraph Style');
  }

  function toggleList(tag) {
    const selection = getSelection();
    if (!selection?.rangeCount) return false;
    const range = selection.getRangeAt(0);
    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer : range.startContainer.parentElement;
    const existing = element?.closest('ul, ol');
    if (existing) {
      if (!existing.contains(range.endContainer)) return false;
      if (existing.localName !== tag) return replaceContainer(existing, tag, 'Change List Style');
      const groups = Array.from(existing.children).filter(node => node.localName === 'li').map(item => {
        const hasBlocks = item.querySelector(':scope > p, :scope > div, :scope > ul, :scope > ol, :scope > h1, :scope > h2, :scope > h3');
        const wrapper = hasBlocks ? null : cleanReplacement(item, 'p');
        return { item, wrapper, nodes: wrapper ? [wrapper] : Array.from(item.childNodes) };
      });
      const nodes = groups.flatMap(group => group.nodes);
      if (!nodes.length) return false;
      recordStructuralChange('Remove List', forward => {
        if (forward) {
          for (const group of groups) group.wrapper?.append(...group.item.childNodes);
          existing.replaceWith(...nodes);
        } else {
          nodes[0].before(existing);
          for (const group of groups) {
            group.item.append(...(group.wrapper ? group.wrapper.childNodes : group.nodes));
            group.wrapper?.remove();
          }
        }
        const target = forward ? nodes.find(node => node instanceof Element) : existing;
        if (target) selectContents(target);
      });
      return true;
    }
    const block = element?.closest('p, h1, h2, h3, h4, h5, h6');
    if (!block || !block.contains(range.endContainer)) return false;
    const list = document.createElement(tag);
    const item = document.createElement('li');
    list.append(item);
    recordStructuralChange('Create List', forward => {
      if (forward) {
        block.before(list);
        item.append(block);
      } else list.replaceWith(block);
      selectContents(block);
    });
    return true;
  }

  function splitParagraphListItem(event) {
    if (!editing || event.key !== 'Enter' || event.shiftKey || event.isComposing) return;
    const selection = window.getSelection();
    if (!selection?.rangeCount) return;
    const range = selection.getRangeAt(0);
    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer : range.startContainer.parentElement;
    const item = element?.closest('li');
    const paragraph = element?.closest('p, div');
    if (!item || !paragraph || !item.contains(paragraph) || !item.contains(range.endContainer)) return;
    // Never round-trip executable/inert embedded data through an editing command.
    if (item.querySelector('script, style, iframe, object')) return;
    const first = item.cloneNode(true);
    const copies = new Map();
    cloneNodeMap(item, first, copies);
    const selected = document.createRange();
    selected.setStart(copies.get(range.startContainer), range.startOffset);
    selected.setEnd(copies.get(range.endContainer), range.endOffset);
    selected.deleteContents();
    const tail = document.createRange();
    tail.setStart(selected.startContainer, selected.startOffset);
    tail.setEnd(first, first.childNodes.length);
    const second = item.cloneNode(false);
    second.appendChild(tail.extractContents());
    second.removeAttribute('id');
    second.querySelectorAll('[id]').forEach(node => node.removeAttribute('id'));
    for (const half of [first, second]) {
      if (!half.textContent.trim()) half.innerHTML = '<p><br></p>';
    }
    event.preventDefault();
    recordStructuralChange('Split List Item', forward => applyListChange({ original: item, first, second }, forward));
  }

  function applyListChange(change, forward) {
    const { original, first, second } = change;
    if (forward) original.replaceWith(first, second);
    else {
      first.replaceWith(original);
      second.remove();
    }
    const target = forward ? second : original;
    const caret = document.createRange();
    caret.selectNodeContents(target.querySelector('p, div') ?? target);
    caret.collapse(forward);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(caret);
  }

  document.addEventListener('keydown', splitParagraphListItem, true);

  document.addEventListener('paste', event => {
    if (!editing || !editingHosts.size) return;
    event.preventDefault();
    const text = event.clipboardData?.getData('text/plain') ?? '';
    if (text) document.execCommand('insertText', false, text);
  }, true);

  for (const eventName of ['click', 'auxclick']) {
    document.addEventListener(eventName, event => {
      if (event.target instanceof Element && event.target.closest('a[href]')) event.preventDefault();
    }, true);
  }
  document.addEventListener('submit', event => event.preventDefault(), true);
  document.addEventListener('dragover', event => event.preventDefault(), true);
  document.addEventListener('drop', event => event.preventDefault(), true);
  document.addEventListener('input', event => {
    if (!editing) return;
    const target = event.target;
    if (target instanceof Node && Array.from(editingHosts).some(host => host === target || host.contains(target))) {
      scheduleChange();
    }
  }, true);

  window.kiln = {
    setEditing,
    serialize,
    outline,
    focusHeading,
    format,
    stylesheets,
    setStylesheet,
    applyStructuralChange
  };

  setEditing(false);
  queueMicrotask(() => notify('ready', true));
})();
