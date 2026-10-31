import Foundation

/// 只在实际渲染后的 DOM 上提取正文；Swift 不再用另一套 HTML 正则猜测页面文本。
enum ReaderTextScripts {
    static let source = #"""
    const dreaderTextContainers = new Set([
        'P', 'DIV', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'LI', 'DT', 'DD',
        'TD', 'TH', 'FIGCAPTION', 'BLOCKQUOTE', 'PRE', 'ASIDE', 'SECTION',
        'ARTICLE', 'NAV', 'FIGURE', 'TABLE', 'UL', 'OL', 'DL', 'TR',
        'TBODY', 'THEAD', 'TFOOT'
    ]);
    const dreaderTextLeaves = new Set([
        'P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'LI', 'DT', 'DD',
        'TD', 'TH', 'FIGCAPTION', 'BLOCKQUOTE', 'PRE', 'ASIDE'
    ]);
    const dreaderTextExcluded = [
        'script', 'style', 'noscript', 'rt', 'rp', 'button', 'svg',
        '[hidden]', '[aria-hidden="true"]', '.dreader-bilingual-slot',
        '.dreader-bilingual-trans', '.dreader-bilingual-side', '.dreader-thought-dot',
        '.dreader-classic-divider'
    ].join(',');

    function dreaderTextIsExcluded(element) {
        if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
        if (element.closest(dreaderTextExcluded)) return true;
        return element.style.display === 'none' || element.style.visibility === 'hidden';
    }

    // 同一份节点映射用于全文搜索和朗读。只规范化空白，不删除标点附近的内容。
    function dreaderTextMap(root) {
        let text = '';
        let runs = [];
        let pendingSpace = false;
        function append(node) {
            if (!node) {
                pendingSpace = true;
                return;
            }
            const raw = node.nodeValue || '';
            let index = 0;
            while (index < raw.length) {
                if (/\s/.test(raw[index])) {
                    pendingSpace = true;
                    index++;
                    continue;
                }
                const sourceStart = index;
                while (index < raw.length && !/\s/.test(raw[index])) index++;
                if (pendingSpace && text && !text.endsWith(' ')) text += ' ';
                pendingSpace = false;
                const start = text.length;
                text += raw.slice(sourceStart, index);
                runs.push({node, start, end: text.length, sourceStart, sourceEnd: index});
            }
        }
        function visit(node) {
            if (node.nodeType === Node.TEXT_NODE) {
                append(node);
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE || dreaderTextIsExcluded(node)) return;
            if (node.tagName === 'BR') {
                append(null);
                return;
            }
            const isBlock = dreaderTextContainers.has(node.tagName);
            if (isBlock) append(null);
            node.childNodes.forEach(visit);
            if (isBlock) append(null);
        }
        root.childNodes.forEach(visit);
        return {text: text.trim(), runs};
    }

    // 不用额外 span 包住正文，避免改变 EPUB 原有的子选择器和 inline 布局。
    // inline 文本组用 Range 定位；普通块仍使用元素 ID。
    let dreaderReadAloudRanges = new Map();
    window.dreaderClearReadAloudSegments = function() {
        dreaderReadAloudRanges.clear();
    };
    function dreaderTextMapInlineRanges(root) {
        function flush(nodes, before) {
            if (!nodes.length) return;
            const hasText = nodes.some(node => {
                if (node.nodeType === Node.TEXT_NODE) return /\S/.test(node.nodeValue || '');
                return node.nodeType === Node.ELEMENT_NODE && !dreaderTextIsExcluded(node)
                    && /\S/.test(node.textContent || '');
            });
            if (!hasText) return;
            const range = document.createRange();
            const parent = (before || nodes[nodes.length - 1]).parentNode;
            if (!parent) return;
            range.selectNodeContents(parent);
            range.setStartBefore(nodes[0]);
            range.setEndAfter(nodes[nodes.length - 1]);
            const text = dreaderTextMap(range.cloneContents()).text;
            if (text) dreaderReadAloudRanges.set(dreaderReadAloudRanges.size, {range, text, parent});
        }
        function group(container) {
            let inline = [];
            Array.from(container.childNodes).forEach(child => {
                if (child.nodeType === Node.ELEMENT_NODE && dreaderTextIsExcluded(child)) return;
                if (child.nodeType === Node.ELEMENT_NODE && dreaderTextContainers.has(child.tagName)) {
                    flush(inline, child);
                    inline = [];
                    if (!dreaderTextLeaves.has(child.tagName)) {
                        group(child);
                    }
                } else {
                    inline.push(child);
                }
            });
            flush(inline, null);
        }
        group(root);
    }

    window.dreaderReadAloudSegments = function() {
        const root = document.getElementById('dreader-chapter-body');
        if (!root) return [];
        dreaderReadAloudRanges.clear();
        root.querySelectorAll('.dreader-read-aloud-active').forEach(element => {
            element.classList.remove('dreader-read-aloud-active');
        });
        root.querySelectorAll('[data-dreader-read-aloud]').forEach(element => {
            element.removeAttribute('data-dreader-read-aloud');
        });
        dreaderTextMapInlineRanges(root);
        const selector = Array.from(dreaderTextLeaves).join(',');
        const blocks = [];
        root.querySelectorAll(selector).forEach(element => {
            if (dreaderTextIsExcluded(element)) return;
            if (element.parentElement && element.parentElement.closest(selector)) return;
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return;
            const text = dreaderTextMap(element).text;
            if (text) blocks.push({element, text});
        });
        // 按 DOM 位置合并块与未包裹 inline 文本，不让 Range 的收集顺序改变朗读顺序。
        const ranges = Array.from(dreaderReadAloudRanges.entries());
        blocks.forEach(item => ranges.push([0, item]));
        ranges.sort((a, b) => {
            const itemA = a[1];
            const itemB = b[1];
            if (itemA.range && itemB.range) {
                return itemA.range.compareBoundaryPoints(Range.START_TO_START, itemB.range);
            }
            if (itemA.range) {
                const rangeB = document.createRange();
                rangeB.selectNode(itemB.element);
                return itemA.range.compareBoundaryPoints(Range.START_TO_START, rangeB);
            }
            if (itemB.range) {
                const rangeA = document.createRange();
                rangeA.selectNode(itemA.element);
                return rangeA.compareBoundaryPoints(Range.START_TO_START, itemB.range);
            }
            const position = itemA.element.compareDocumentPosition(itemB.element);
            if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
            if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
            return 0;
        });
        return ranges.map((entry, id) => {
            const item = entry[1];
            dreaderReadAloudRanges.set(id, item.range ? item : null);
            if (item.element) item.element.setAttribute('data-dreader-read-aloud', String(id));
            return {id, text: item.text};
        });
    };

    window.dreaderScrollToReadAloudSegment = function(id) {
        const root = document.getElementById('dreader-chapter-body');
        if (!root) return false;
        const item = dreaderReadAloudRanges.get(id);
        const element = (item && item.element)
            || root.querySelector('[data-dreader-read-aloud="' + id + '"]')
            || (item && item.range ? item.parent : null);
        if (!element) return false;
        root.querySelectorAll('.dreader-read-aloud-active').forEach(active => {
            active.classList.remove('dreader-read-aloud-active');
        });
        element.classList.add('dreader-read-aloud-active');
        element.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
        return true;
    };

    window.dreaderScrollToSearchMatch = function(keyword, matchIndex) {
        const root = document.getElementById('dreader-chapter-body');
        if (!root || !keyword || !Number.isInteger(matchIndex) || matchIndex < 0) return false;
        const query = keyword.replace(/\s+/g, ' ').trim().toLowerCase();
        if (!query) return false;
        const mapped = dreaderTextMap(root);
        const haystack = mapped.text.toLowerCase();
        let start = -1;
        for (let count = 0; count <= matchIndex; count++) {
            start = haystack.indexOf(query, start + 1);
            if (start < 0) return false;
        }
        const end = start + query.length;
        const first = mapped.runs.find(run => run.end > start);
        const last = mapped.runs.find(run => run.end >= end);
        if (!first || !last) return false;
        try {
            const range = document.createRange();
            range.setStart(first.node, first.sourceStart + start - first.start);
            range.setEnd(last.node, last.sourceStart + end - last.start);
            // 不拆已有 mark，也不制造重复的划线 ID；用系统选区呈现命中。
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            const element = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
                ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
            if (element) element.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
            return true;
        } catch (error) {
            console.error('Error locating search match:', error);
            return false;
        }
    };
    """#
}
