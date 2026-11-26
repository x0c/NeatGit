// NeatGit 差异页面：CodeMirror 6 实现（并排 / 单栏、行级与行内高亮、跟随外观）。
// 语法着色按文件类型接入（languageSupport.js）；差异视图内可查找（⌘F）。
import { MergeView, unifiedMergeView, getChunks, getOriginalDoc } from '@codemirror/merge';
import {
  EditorView,
  lineNumbers,
  lineNumberMarkers,
  drawSelection,
  highlightActiveLineGutter,
  keymap,
  ViewPlugin,
  Decoration,
  GutterMarker,
  BlockType
} from '@codemirror/view';
import { search, searchKeymap, searchPanelOpen, getSearchQuery, SearchQuery, highlightSelectionMatches } from '@codemirror/search';
import { EditorState, Compartment, RangeSet, RangeSetBuilder, StateEffect, StateField, Text } from '@codemirror/state';
import { createDiffConfig } from './diffAlgorithm.js';
import {
  collapsedUnchanged,
  createCollapsedState,
  collapseSyncEffect
} from './collapsedUnchanged.js';
import { resolveLanguageSupport, syntaxHighlightingExtension } from './languageSupport.js';
import './styles.css';

const container = document.getElementById('editor-shell');
const diffContainer = document.getElementById('diff-editor');
// 可用宽度低于这个值时改用单栏（统一视图）。
const INLINE_DIFF_BREAKPOINT = 960;
// 与编辑器默认的分行规则一致；单栏视图的原文要按行传入。
const LINE_BREAK = /\r\n?|\n/;

const DIFF_CONFIG = createDiffConfig();

const darkAppearance = window.matchMedia('(prefers-color-scheme: dark)');
const increasedContrast = window.matchMedia('(prefers-contrast: more)');
const forcedColors = window.matchMedia('(forced-colors: active)');
let usesNativeAppearance = false;
// 已生效的外观快照，用于让重复调用 setAppearance 成为无副作用的空操作。
let appliedAppearance = null;
let appliedHighContrast = null;

// 页面初始化即按系统外观定调，避免宿主尚未调用前先闪一帧浅色。
document.documentElement.lang = 'zh-CN';
diffContainer.setAttribute('aria-label', '代码差异预览');

function applyAppearance(appearance, highContrast = false) {
  const isDark = appearance === 'dark';
  const isHighContrast = Boolean(highContrast);

  // 幂等：外观与对比度均无变化时不做任何写入，避免重复切主题触发重绘。
  if (appliedAppearance === (isDark ? 'dark' : 'light') && appliedHighContrast === isHighContrast) {
    return;
  }
  appliedAppearance = isDark ? 'dark' : 'light';
  appliedHighContrast = isHighContrast;

  // 颜色全部走样式表里的变量，这里只改根节点属性，不重建视图。
  document.documentElement.dataset.appearance = isDark ? 'dark' : 'light';
  document.documentElement.dataset.highContrast = String(isHighContrast);
}

function applySystemAppearance() {
  if (!usesNativeAppearance) {
    applyAppearance(darkAppearance.matches ? 'dark' : 'light', increasedContrast.matches || forcedColors.matches);
  }
}

applySystemAppearance();

// 最近一次生效的载荷。
let currentPayload = null;
// 并排视图与单栏视图同一时刻只会存在一个。
let splitView = null;
let unifiedView = null;
let isInlineMode = false;
// 已生效的「只看变更」状态，避免重复开关触发无意义重算。
let appliedChangesOnly = false;
// 折叠状态（并排时两侧共用）与折叠扩展的挂载隔间：开关时只重新配置隔间，不重建视图。
let collapsedState = null;
let collapseCompartment = null;

// 行号格子的底色标记：按侧区分「删除」「新增」，单栏里行内改动的行用中性的「修改」标记。
function createNumberMarker(className) {
  const marker = new GutterMarker();
  marker.elementClass = className;
  return marker;
}
const removedNumberMarker = createNumberMarker('ng-removed-number');
const insertedNumberMarker = createNumberMarker('ng-inserted-number');
const modifiedNumberMarker = createNumberMarker('ng-modified-number');

function buildChangedLineMarkers(state, detectInlineChange) {
  const info = getChunks(state);
  if (!info) {
    // 对比块还没就绪：返回空值，等下一次事务再算。
    return null;
  }
  const isOriginalSide = info.side === 'a';
  const doc = state.doc;
  const builder = new RangeSetBuilder();
  for (const chunk of info.chunks) {
    const from = isOriginalSide ? chunk.fromA : chunk.fromB;
    if (from === (isOriginalSide ? chunk.toA : chunk.toB)) {
      continue;
    }
    const marker = isOriginalSide
      ? removedNumberMarker
      : detectInlineChange && displaysInline(state, chunk)
        ? modifiedNumberMarker
        : insertedNumberMarker;
    const firstLine = doc.lineAt(from).number;
    const lastLine = doc.lineAt(isOriginalSide ? chunk.endA : chunk.endB).number;
    for (let number = firstLine; number <= lastLine; number++) {
      builder.add(doc.line(number).from, doc.line(number).from, marker);
    }
  }
  return builder.finish();
}

// 与库的内联显示条件一致：两侧行数相同、少于 10 行、删除内容里没有换行、删除量很小。
function displaysInline(state, chunk) {
  const original = getOriginalDoc(state);
  const lines = original.lineAt(chunk.endA).number - original.lineAt(chunk.fromA).number + 1;
  if (state.doc.lineAt(chunk.endB).number - state.doc.lineAt(chunk.fromB).number + 1 !== lines || lines >= 10) {
    return false;
  }
  let deletedLength = 0;
  for (const change of chunk.changes) {
    if (change.fromA === change.toA) {
      continue;
    }
    const deleted = original.sliceString(chunk.fromA + change.fromA, chunk.fromA + change.toA);
    if (deleted.includes('\n')) {
      return false;
    }
    deletedLength += change.toA - change.fromA;
  }
  return deletedLength < chunk.endA - chunk.fromA - lines * 2;
}

function changedLineNumberTint(detectInlineChange) {
  // 文档只读，改动块不会变：算一次就够。
  // 并排视图建立时对比块还没挂上（库随后才补进去），所以要留一个「拿到结果后再算一次」的更新入口；
  // 并且必须等对比块就绪再算，提前算会得到空结果并被一直沿用。
  const tint = StateField.define({
    create: (state) => buildChangedLineMarkers(state, detectInlineChange),
    update: (markers, transaction) => markers || buildChangedLineMarkers(transaction.state, detectInlineChange),
    provide: (field) => lineNumberMarkers.from(field, (markers) => markers || RangeSet.empty)
  });
  return tint;
}

// 并排时让另一栏也显示查找结果：查找面板只开在聚焦的那一栏，另一栏不另开面板，
// 只接收同一份查找词，把命中处用同样的样式标出来（与现有页面一致：两侧的结果都能看到）。
const setMirrorQuery = StateEffect.define();
const mirrorQuery = StateField.define({
  create: () => null,
  update(value, transaction) {
    let next = value;
    for (const effect of transaction.effects) {
      if (effect.is(setMirrorQuery)) {
        next = effect.value;
      }
    }
    return next;
  }
});
const mirrorSearchMatch = Decoration.mark({ class: 'cm-searchMatch' });
const mirrorSearchMatches = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = buildMirrorSearchMatches(view);
    }
    update(update) {
      if (update.state.field(mirrorQuery) !== update.startState.field(mirrorQuery) || update.viewportChanged) {
        this.decorations = buildMirrorSearchMatches(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations }
);

// 只标出视口附近的命中处，滚动或改词时重算。
function buildMirrorSearchMatches(view) {
  const query = view.state.field(mirrorQuery);
  if (!query || !query.valid) {
    return Decoration.none;
  }
  const builder = new RangeSetBuilder();
  for (const range of view.visibleRanges) {
    for (let cursor = query.getCursor(view.state, range.from, range.to); !cursor.next().done; ) {
      builder.add(cursor.value.from, cursor.value.to, mirrorSearchMatch);
    }
  }
  return builder.finish();
}

function syncSearchWithSibling() {
  return EditorView.updateListener.of((update) => {
    const view = update.view;
    const sibling = splitView ? (view === splitView.a ? splitView.b : view === splitView.b ? splitView.a : null) : null;
    if (!sibling) {
      return;
    }
    // 自己这一栏面板开着时，对方显示自己的查找词；自己这一栏面板没开时，对方不再跟着显示。
    // 这个版本的库从状态里取到的是查找条件的描述，要再包成可用的查找对象。
    const query = searchPanelOpen(view.state) ? new SearchQuery(getSearchQuery(view.state)) : null;
    if (sibling.state.field(mirrorQuery) !== query && !(query && sibling.state.field(mirrorQuery)?.eq(query))) {
      sibling.dispatch({ effects: setMirrorQuery.of(query) });
    }
  });
}

function editorExtensions(languageSupport, detectInlineChange) {
  return [
    lineNumbers(),
    drawSelection(),
    // 与现有页面一致：光标所在行的行号高亮。
    highlightActiveLineGutter(),
    // 差异视图内查找：⌘F 打开面板，Esc 关闭；并排时面板开在聚焦的那一侧，另一栏同步高亮。
    // 文档只读，面板里不会出现替换入口。面板文字沿用库自带的英文（与现有页面一致）。
    search({ top: true }),
    keymap.of(searchKeymap),
    mirrorQuery,
    mirrorSearchMatches,
    syncSearchWithSibling(),
    // 选中一段文字时高亮其余相同内容（与现有页面一致）。
    highlightSelectionMatches(),
    // 语法颜色要显式启用才生效；没有语言支持时这一项不起作用。
    languageSupport || [],
    syntaxHighlightingExtension(),
    changedLineNumberTint(detectInlineChange),
    // 只读但可获得焦点：用状态层的只读开关，内容节点才保持可聚焦（点击后能直接 ⌘F）。
    // 不要再关「可编辑」：那样内容节点不可聚焦，点击后按键到不了编辑器。光标用样式隐藏。
    EditorState.readOnly.of(true),
    EditorView.contentAttributes.of({ tabindex: '0' }),
    EditorState.tabSize.of(4)
  ];
}

function collapseExtensions() {
  return appliedChangesOnly ? collapsedUnchanged(collapsedState) : [];
}

// 折叠状态变化：通知当前所有视图（并排时是左右两栏）重算，保持同步。
function collapseStateChanged() {
  const effect = collapseSyncEffect(collapsedState);
  for (const view of activeViews()) {
    view.dispatch({ effects: effect });
  }
}

function destroyViews() {
  if (splitView) {
    splitView.destroy();
    splitView = null;
  }
  if (unifiedView) {
    unifiedView.destroy();
    unifiedView = null;
  }
}

function activeViews() {
  return splitView ? [splitView.a, splitView.b] : unifiedView ? [unifiedView] : [];
}

function activeScroller() {
  return unifiedView ? unifiedView.scrollDOM : splitView.dom;
}

function firstChangedPosition() {
  const chunks = unifiedView ? getChunks(unifiedView.state)?.chunks : splitView?.chunks;
  return chunks && chunks.length ? chunks[0].fromB : null;
}

// 记下当前滚动位置上第一行真实内容的行号，切换并排 / 单栏后回到同一行。
function captureTopLine() {
  const view = unifiedView || splitView?.b;
  if (!view) {
    return null;
  }
  const scrollTop = activeScroller().scrollTop;
  for (const block of view.viewportLineBlocks) {
    if (block.type === BlockType.Text && block.bottom > scrollTop + 1) {
      return view.state.doc.lineAt(block.from).number;
    }
  }
  return null;
}

function scrollToLine(lineNumber) {
  const view = unifiedView || splitView?.b;
  view.dispatch({
    effects: EditorView.scrollIntoView(view.state.doc.line(Math.min(lineNumber, view.state.doc.lines)).from, { y: 'start' })
  });
}

// 打开时定位到第一处差异。单栏里删除内容显示在新增行的上方，要等排版量出高度后把这段也算进可视范围。
function revealFirstDiff() {
  const position = firstChangedPosition();
  if (position === null) {
    return;
  }
  if (unifiedView) {
    window.requestAnimationFrame(() => {
      if (!unifiedView) {
        return;
      }
      let margin = 4;
      for (const block of unifiedView.viewportLineBlocks) {
        if (block.type === BlockType.Widget && block.from === position) {
          margin = block.height + 4;
        }
      }
      unifiedView.dispatch({ effects: EditorView.scrollIntoView(position, { y: 'start', yMargin: margin }) });
    });
  } else {
    splitView.b.dispatch({ effects: EditorView.scrollIntoView(position, { y: 'center' }) });
  }
}

function applyAriaLabels() {
  if (!currentPayload) {
    return;
  }
  const { filePath, originalLabel, modifiedLabel } = currentPayload;
  const original = `原文，只读，${filePath}，${originalLabel}`;
  const modified = `修改后，只读，${filePath}，${modifiedLabel}`;
  const setLabel = (view, label) => view.contentDOM.setAttribute('aria-label', label);
  if (splitView) {
    setLabel(splitView.a, original);
    setLabel(splitView.b, modified);
  } else if (unifiedView) {
    setLabel(unifiedView, `${modified}，对比${originalLabel}`);
  }
}

function renderDiff(restoreLine) {
  const payload = currentPayload;
  const scrollTop = restoreLine ? activeScroller().scrollTop : 0;
  // 两侧编辑器用同一种语言；提示为空或没有对应语法包时为纯文本。
  const languageSupport = resolveLanguageSupport(payload.languageHint);
  destroyViews();
  diffContainer.classList.toggle('ng-unified', isInlineMode);
  collapsedState = createCollapsedState();
  collapsedState.onChange = collapseStateChanged;
  collapseCompartment = new Compartment();

  if (isInlineMode) {
    unifiedView = new EditorView({
      parent: diffContainer,
      state: EditorState.create({
        doc: payload.modifiedText,
        extensions: [
          unifiedMergeView({
            original: Text.of(payload.originalText.split(LINE_BREAK)),
            // 只读差异不提供「接受 / 拒绝」按钮。
            mergeControls: false,
            // 同一行上的小改动内联显示删除与新增，而不是拆成上下两行。
            allowInlineDiffs: true,
            diffConfig: DIFF_CONFIG
          }),
          collapseCompartment.of(collapseExtensions()),
          ...editorExtensions(languageSupport, true)
        ]
      })
    });
  } else {
    splitView = new MergeView({
      a: {
        doc: payload.originalText,
        extensions: [...editorExtensions(languageSupport, false), collapseCompartment.of(collapseExtensions())]
      },
      b: {
        doc: payload.modifiedText,
        extensions: [...editorExtensions(languageSupport, false), collapseCompartment.of(collapseExtensions())]
      },
      parent: diffContainer,
      // 库默认会在两侧之间显示「回退此块」按钮列，只读差异里必须关掉。
      revertControls: 'none',
      diffConfig: DIFF_CONFIG
    });
  }

  applyAriaLabels();
  if (restoreLine) {
    activeScroller().scrollTop = scrollTop;
    const line = restoreLine;
    window.requestAnimationFrame(() => scrollToLine(line));
  } else {
    revealFirstDiff();
  }
}

function applyResponsiveLayout() {
  const nextInlineMode = container.clientWidth > 0 && container.clientWidth < INLINE_DIFF_BREAKPOINT;
  if (nextInlineMode === isInlineMode) {
    return;
  }
  // 切换并排 / 单栏要换一种视图：带着当前滚动位置重建，内容不丢。
  const restoreLine = currentPayload ? captureTopLine() : null;
  isInlineMode = nextInlineMode;
  if (currentPayload) {
    renderDiff(restoreLine);
  }
}

const resizeObserver = new ResizeObserver(() => {
  applyResponsiveLayout();
});
resizeObserver.observe(container);

window.neatGit = {
  // 宿主调用：window.neatGit.setDiff(payload)；文件路径与两侧文本都没变时不重复渲染。
  setDiff(payload) {
    const next = {
      filePath: payload.filePath ?? '',
      modeTitle: payload.modeTitle ?? '',
      originalLabel: payload.originalLabel ?? '',
      modifiedLabel: payload.modifiedLabel ?? '',
      originalText: payload.originalText ?? '',
      modifiedText: payload.modifiedText ?? '',
      languageHint: payload.languageHint ?? null
    };
    const contentChanged =
      currentPayload === null ||
      currentPayload.filePath !== next.filePath ||
      currentPayload.originalText !== next.originalText ||
      currentPayload.modifiedText !== next.modifiedText ||
      currentPayload.languageHint !== next.languageHint;
    currentPayload = next;
    // 内容没变时只更新无障碍标签（两侧标签可能随「未暂存 / 已暂存」切换而变）。
    if (contentChanged || (!splitView && !unifiedView)) {
      renderDiff(null);
    } else {
      applyAriaLabels();
    }
  },
  // 宿主调用：window.neatGit.setChangesOnly(true)；和文件内容解耦，切换时不重传正文。
  setChangesOnly(showChangesOnly) {
    const next = Boolean(showChangesOnly);
    if (next === appliedChangesOnly) {
      return;
    }
    appliedChangesOnly = next;
    // 只重新配置折叠扩展：不重建视图，也不需要宿主重传正文。
    if (collapseCompartment) {
      const effect = collapseCompartment.reconfigure(collapseExtensions());
      for (const view of activeViews()) {
        view.dispatch({ effects: effect });
      }
    }
  },
  // 宿主调用：window.neatGit.setAppearance('dark')，可选第二参数承接系统高对比偏好。
  setAppearance(appearance, highContrast = false) {
    usesNativeAppearance = true;
    applyAppearance(appearance === 'dark' ? 'dark' : 'light', highContrast);
  }
};

darkAppearance.addEventListener('change', applySystemAppearance);
increasedContrast.addEventListener('change', applySystemAppearance);
forcedColors.addEventListener('change', applySystemAppearance);
