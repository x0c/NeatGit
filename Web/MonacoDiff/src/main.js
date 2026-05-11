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
const MONACO_THEME_NAME = 'neatgit-macos-light';

monaco.editor.defineTheme(MONACO_THEME_NAME, {
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

monaco.editor.setTheme(MONACO_THEME_NAME);

const diffEditor = monaco.editor.createDiffEditor(diffEditorContainer, {
  automaticLayout: true,
  diffAlgorithm: 'advanced',
  enableSplitViewResizing: true,
  fontFamily: 'SF Mono, ui-monospace, Menlo, monospace',
  fontSize: 12.5,
  minimap: {
    enabled: false
  },
  readOnly: true,
  renderIndicators: true,
  renderOverviewRuler: false,
  renderSideBySide: true,
  scrollBeyondLastLine: false,
  theme: MONACO_THEME_NAME,
  useInlineViewWhenSpaceIsLimited: false
});

const originalModel = monaco.editor.createModel('', 'plaintext');
const modifiedModel = monaco.editor.createModel('', 'plaintext');
diffEditor.setModel({
  original: originalModel,
  modified: modifiedModel
});

let lastRenderedIdentity = null;
let isInlineMode = false;
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

window.neatGit = {
  setDiff(payload) {
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

if (window.webkit?.messageHandlers?.neatGitReady) {
  window.webkit.messageHandlers.neatGitReady.postMessage({ ready: true });
}
