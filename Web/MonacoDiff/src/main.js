import * as monaco from 'monaco-editor';
import editorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
import jsonWorker from 'monaco-editor/esm/vs/language/json/json.worker?worker';
import cssWorker from 'monaco-editor/esm/vs/language/css/css.worker?worker';
import htmlWorker from 'monaco-editor/esm/vs/language/html/html.worker?worker';
import tsWorker from 'monaco-editor/esm/vs/language/typescript/ts.worker?worker';
import './styles.css';

self.MonacoEnvironment = {
  getWorker(_, label) {
    switch (label) {
      case 'json':
        return new jsonWorker();
      case 'css':
      case 'scss':
      case 'less':
        return new cssWorker();
      case 'html':
      case 'handlebars':
      case 'razor':
        return new htmlWorker();
      case 'typescript':
      case 'javascript':
        return new tsWorker();
      default:
        return new editorWorker();
    }
  }
};

const container = document.getElementById('editor-shell');
const diffEditorContainer = document.getElementById('diff-editor');
const INLINE_DIFF_BREAKPOINT = 960;
// 只看变更时保留的上下文行数、触发折叠的最小未变更行数，以及点击一次展开的行数。
const UNCHANGED_CONTEXT_LINE_COUNT = 3;
const UNCHANGED_MINIMUM_LINE_COUNT = 3;
const UNCHANGED_REVEAL_LINE_COUNT = 20;
const LIGHT_THEME_NAME = 'neatgit-macos-light';
const DARK_THEME_NAME = 'neatgit-macos-dark';
const darkAppearance = window.matchMedia('(prefers-color-scheme: dark)');
const increasedContrast = window.matchMedia('(prefers-contrast: more)');
const forcedColors = window.matchMedia('(forced-colors: active)');
let usesNativeAppearance = false;
// 已生效的外观快照，用于让重复调用 setAppearance 成为无副作用的空操作。
let appliedAppearance = null;
let appliedHighContrast = null;

document.documentElement.lang = 'zh-CN';
diffEditorContainer.setAttribute('aria-label', '代码差异预览');

// 浅色：对齐 macOS 浅色外观与 Xcode 浅色主题。
monaco.editor.defineTheme(LIGHT_THEME_NAME, {
  base: 'vs',
  inherit: true,
  rules: [],
  colors: {
    'editor.background': '#FBFBFD',
    'editor.foreground': '#24303C',
    'editorLineNumber.foreground': '#A0A8B3',
    'editorLineNumber.activeForeground': '#5D6874',
    'editor.lineHighlightBackground': '#F3F5F8',
    'editor.selectionBackground': '#DCE7F7',
    'editor.inactiveSelectionBackground': '#E8EEF8',
    'editorIndentGuide.background1': '#E6EAF0',
    'editorIndentGuide.activeBackground1': '#CAD2DD',
    'editorWhitespace.foreground': '#D6DCE5',
    'editorOverviewRuler.border': '#00000000',
    'editorGutter.background': '#F8F9FB',
    'editorWidget.border': '#D6DCE5',
    'editorHoverWidget.border': '#D6DCE5',
    'editorSuggestWidget.border': '#D6DCE5',
    'diffEditor.diagonalFill': '#F3F5F8',
    'diffEditor.insertedTextBackground': '#5FA37322',
    'diffEditor.removedTextBackground': '#C97C7C1F',
    'diffEditor.insertedLineBackground': '#E7F2EA',
    'diffEditor.removedLineBackground': '#F7E9E7',
    'diffEditor.insertedTextBorder': '#8DB99A66',
    'diffEditor.removedTextBorder': '#D7A2A266',
    'diffEditor.border': '#D8DEE8',
    'diffEditorGutter.insertedLineBackground': '#DDEEE2',
    'diffEditorGutter.removedLineBackground': '#F2DEDB'
  }
});

// 深色：中性深灰背景（非纯黑），新增/删除行用低亮度低饱和绿红。
monaco.editor.defineTheme(DARK_THEME_NAME, {
  base: 'vs-dark',
  inherit: true,
  rules: [],
  colors: {
    'editor.background': '#1F1F22',
    'editor.foreground': '#D3D6DB',
    'editorLineNumber.foreground': '#5B5F66',
    'editorLineNumber.activeForeground': '#C3C7CD',
    'editor.lineHighlightBackground': '#26262A',
    'editor.selectionBackground': '#3A4A63',
    'editor.inactiveSelectionBackground': '#2E3037',
    'editorIndentGuide.background1': '#2C2C31',
    'editorIndentGuide.activeBackground1': '#454A52',
    'editorWhitespace.foreground': '#3A3D44',
    'editorOverviewRuler.border': '#00000000',
    'editorGutter.background': '#1B1B1E',
    'editorWidget.border': '#3A3D44',
    'editorHoverWidget.border': '#3A3D44',
    'editorSuggestWidget.border': '#3A3D44',
    'diffEditor.diagonalFill': '#2A2A2F',
    'diffEditor.insertedTextBackground': '#3A6B4A44',
    'diffEditor.removedTextBackground': '#7A3B3B44',
    'diffEditor.insertedLineBackground': '#1E2E22',
    'diffEditor.removedLineBackground': '#2E1F1F',
    'diffEditor.insertedTextBorder': '#4C8A5F55',
    'diffEditor.removedTextBorder': '#A05C5C55',
    'diffEditor.border': '#33363C',
    'diffEditorGutter.insertedLineBackground': '#243528',
    'diffEditorGutter.removedLineBackground': '#352525'
  }
});

function applyAppearance(appearance, highContrast = false) {
  const isDark = appearance === 'dark';
  const isHighContrast = Boolean(highContrast);

  // 幂等：外观与对比度均无变化时不做任何写入，避免重复切主题触发重绘。
  if (appliedAppearance === (isDark ? 'dark' : 'light') && appliedHighContrast === isHighContrast) {
    return;
  }
  appliedAppearance = isDark ? 'dark' : 'light';
  appliedHighContrast = isHighContrast;

  const theme = isHighContrast
    ? (isDark ? 'hc-black' : 'hc-light')
    : (isDark ? DARK_THEME_NAME : LIGHT_THEME_NAME);
  document.documentElement.dataset.appearance = isDark ? 'dark' : 'light';
  document.documentElement.dataset.highContrast = String(isHighContrast);
  monaco.editor.setTheme(theme);
}

function applySystemAppearance() {
  if (!usesNativeAppearance) {
    applyAppearance(darkAppearance.matches ? 'dark' : 'light', increasedContrast.matches || forcedColors.matches);
  }
}

// 页面初始化即按系统外观定调，避免宿主尚未调用前先闪一帧浅色。
applySystemAppearance();

const diffEditor = monaco.editor.createDiffEditor(diffEditorContainer, {
  automaticLayout: true,
  autoDetectHighContrast: false,
  ariaLabel: '代码差异预览',
  originalAriaLabel: '原文，只读',
  modifiedAriaLabel: '修改后，只读',
  originalEditable: false,
  diffAlgorithm: 'advanced',
  enableSplitViewResizing: true,
  fontFamily: 'SF Mono, ui-monospace, Menlo, monospace',
  fontSize: 12.5,
  minimap: {
    enabled: false
  },
  readOnly: true,
  readOnlyMessage: { value: '这里只能查看差异，请在代码编辑器中修改文件。' },
  renderIndicators: true,
  renderOverviewRuler: false,
  renderSideBySide: true,
  scrollBeyondLastLine: false,
  useInlineViewWhenSpaceIsLimited: false,
  hideUnchangedRegions: {
    enabled: false,
    contextLineCount: UNCHANGED_CONTEXT_LINE_COUNT,
    minimumLineCount: UNCHANGED_MINIMUM_LINE_COUNT,
    revealLineCount: UNCHANGED_REVEAL_LINE_COUNT
  }
});

const originalModel = monaco.editor.createModel('', 'plaintext');
const modifiedModel = monaco.editor.createModel('', 'plaintext');
diffEditor.setModel({
  original: originalModel,
  modified: modifiedModel
});

let lastRenderedIdentity = null;
let isInlineMode = false;
// 已生效的「只看变更」状态，避免重复 updateOptions 触发无意义重算。
let appliedChangesOnly = false;
const resizeObserver = new ResizeObserver(() => {
  applyResponsiveLayout();
  diffEditor.layout();
});
resizeObserver.observe(container);
window.addEventListener('resize', () => {
  applyResponsiveLayout();
  diffEditor.layout();
});

function resolveLanguage(languageHint) {
  if (!languageHint) {
    return 'plaintext';
  }

  const availableLanguages = monaco.languages.getLanguages().map((language) => language.id);
  return availableLanguages.includes(languageHint) ? languageHint : 'plaintext';
}

function applyResponsiveLayout() {
  const nextInlineMode = container.clientWidth > 0 && container.clientWidth < INLINE_DIFF_BREAKPOINT;

  if (nextInlineMode === isInlineMode) {
    return;
  }

  isInlineMode = nextInlineMode;
  diffEditor.updateOptions({
    renderSideBySide: !nextInlineMode,
    experimental: {
      useTrueInlineView: nextInlineMode
    }
  });
  window.requestAnimationFrame(() => {
    diffEditor.layout();
  });
}

// 只看变更：交给 Monaco 折叠未变更区域，保留变更附近的上下文行与真实行号，折叠块可点击展开。
function applyChangesOnly(showChangesOnly) {
  if (appliedChangesOnly === showChangesOnly) {
    return;
  }

  appliedChangesOnly = showChangesOnly;
  diffEditor.updateOptions({
    hideUnchangedRegions: {
      enabled: showChangesOnly,
      contextLineCount: UNCHANGED_CONTEXT_LINE_COUNT,
      minimumLineCount: UNCHANGED_MINIMUM_LINE_COUNT,
      revealLineCount: UNCHANGED_REVEAL_LINE_COUNT
    }
  });

  // 开启选项只是让未变更区域可折叠，区域初始仍是展开态，这里要显式收起一次。
  if (showChangesOnly) {
    diffEditor.collapseAllUnchangedRegions();
  }
}

// 切文件或重算差异后区域会重建，开关仍开启时补一次折叠。
diffEditor.onDidUpdateDiff(() => {
  if (appliedChangesOnly) {
    diffEditor.collapseAllUnchangedRegions();
  }
});

window.neatGit = {
  // 宿主调用：window.neatGit.setChangesOnly(true)；和文件内容解耦，切换时不重传正文。
  setChangesOnly(showChangesOnly) {
    applyChangesOnly(Boolean(showChangesOnly));
  },
  // 宿主调用：window.neatGit.setAppearance('dark')，可选第二参数承接系统高对比偏好。
  setAppearance(appearance, highContrast = false) {
    usesNativeAppearance = true;
    applyAppearance(appearance === 'dark' ? 'dark' : 'light', highContrast);
  },
  setDiff(payload) {
    diffEditor.getOriginalEditor().updateOptions({
      ariaLabel: `原文，只读，${payload.filePath}，${payload.originalLabel}`
    });
    diffEditor.getModifiedEditor().updateOptions({
      ariaLabel: `修改后，只读，${payload.filePath}，${payload.modifiedLabel}`
    });
    const language = resolveLanguage(payload.languageHint);
    const nextIdentity = {
      filePath: payload.filePath,
      originalText: payload.originalText,
      modifiedText: payload.modifiedText,
      language
    };
    const contentChanged =
      lastRenderedIdentity === null ||
      lastRenderedIdentity.filePath !== nextIdentity.filePath ||
      lastRenderedIdentity.originalText !== nextIdentity.originalText ||
      lastRenderedIdentity.modifiedText !== nextIdentity.modifiedText ||
      lastRenderedIdentity.language !== nextIdentity.language;

    if (!contentChanged) {
      return;
    }

    originalModel.setValue(payload.originalText);
    modifiedModel.setValue(payload.modifiedText);
    monaco.editor.setModelLanguage(originalModel, language);
    monaco.editor.setModelLanguage(modifiedModel, language);
    applyResponsiveLayout();
    window.requestAnimationFrame(() => {
      applyResponsiveLayout();
    });
    diffEditor.revealFirstDiff();
    lastRenderedIdentity = nextIdentity;
  }
};

darkAppearance.addEventListener('change', applySystemAppearance);
increasedContrast.addEventListener('change', applySystemAppearance);
forcedColors.addEventListener('change', applySystemAppearance);
