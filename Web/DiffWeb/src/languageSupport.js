// 按文件类型做语法高亮。
// 做法：把语法解析器给出的「标签」映射成固定的类名（ng-syn-*），颜色全部写在样式表的变量里；
// 切换深浅色、高对比时页面脚本只改根节点属性，不需要重建视图。
import { StreamLanguage, syntaxHighlighting, HighlightStyle } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { cpp } from '@codemirror/lang-cpp';
import { css } from '@codemirror/lang-css';
import { go } from '@codemirror/lang-go';
import { html } from '@codemirror/lang-html';
import { java } from '@codemirror/lang-java';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { markdown } from '@codemirror/lang-markdown';
import { php } from '@codemirror/lang-php';
import { python } from '@codemirror/lang-python';
import { rust } from '@codemirror/lang-rust';
import { sql } from '@codemirror/lang-sql';
import { xml } from '@codemirror/lang-xml';
import { yaml } from '@codemirror/lang-yaml';
import { ruby } from '@codemirror/legacy-modes/mode/ruby';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { swift } from '@codemirror/legacy-modes/mode/swift';

/**
 * 宿主给出的「语言提示 → 语法支持」表。提示来自应用按文件扩展名的判定；
 * 表里没有的提示（包括 null、纯文本、没有官方语法包的语言）一律回退纯文本，不会报错。
 */
const languageSupports = {
  // 官方语言包
  c: cpp(),
  cpp: cpp(),
  css: css(),
  go: go(),
  html: html(),
  java: java(),
  javascript: javascript(),
  json: json(),
  markdown: markdown(),
  php: php(),
  python: python(),
  rust: rust(),
  sql: sql(),
  typescript: javascript({ typescript: true }),
  xml: xml(),
  yaml: yaml(),
  // 没有新式语法包、只有官方旧式语法的
  ruby: StreamLanguage.define(ruby),
  shell: StreamLanguage.define(shell),
  swift: StreamLanguage.define(swift)
  // 没有可用语法包、回退纯文本的：kotlin、objective-c、objective-cpp、plaintext。
};

// 返回可直接放进编辑器扩展列表的语法支持；回退时返回 null。
export function resolveLanguageSupport(languageHint) {
  return Object.hasOwn(languageSupports, languageHint) ? languageSupports[languageHint] : null;
}

// 语法支持里的解析器所属的语言对象（新旧两种包的返回类型不同，这里统一取法）。
export function languageOf(syntaxSupport) {
  return syntaxSupport.language || syntaxSupport;
}

// 标签 → 类名。只给类名、不写颜色，颜色由样式表按外观给出。
// 取值顺序有意义：同一个词带多个标签时，排在后面的规则优先级更高。
const syntaxStyle = HighlightStyle.define([
  { tag: [tags.meta, tags.documentMeta, tags.annotation, tags.processingInstruction], class: 'ng-syn-meta' },
  { tag: [tags.comment, tags.lineComment, tags.blockComment, tags.docComment], class: 'ng-syn-comment' },
  { tag: [tags.link], class: 'ng-syn-link' },
  { tag: [tags.url], class: 'ng-syn-link' },
  { tag: [tags.heading], class: 'ng-syn-heading' },
  { tag: [tags.emphasis], class: 'ng-syn-emphasis' },
  { tag: [tags.strong], class: 'ng-syn-strong' },
  { tag: [tags.invalid], class: 'ng-syn-invalid' },
  { tag: [tags.regexp], class: 'ng-syn-regexp' },
  { tag: [tags.string, tags.special(tags.string), tags.docString, tags.character, tags.attributeValue], class: 'ng-syn-string' },
  { tag: [tags.number, tags.integer, tags.float, tags.bool, tags.null, tags.atom, tags.unit], class: 'ng-syn-number' },
  { tag: [tags.keyword, tags.self, tags.modifier, tags.operatorKeyword, tags.controlKeyword, tags.definitionKeyword, tags.moduleKeyword], class: 'ng-syn-keyword' },
  { tag: [tags.typeName, tags.className, tags.namespace, tags.standard(tags.typeName), tags.standard(tags.className), tags.standard(tags.variableName)], class: 'ng-syn-type' },
  { tag: [tags.name, tags.definition(tags.variableName), tags.function(tags.variableName)], class: 'ng-syn-function' },
  { tag: [tags.propertyName, tags.attributeName, tags.labelName], class: 'ng-syn-property' },
  { tag: [tags.tagName], class: 'ng-syn-tag' },
  { tag: [tags.variableName, tags.special(tags.variableName), tags.constant(tags.variableName)], class: 'ng-syn-variable' }
]);

/**
 * 语法高亮扩展。语法颜色必须显式启用才会生效：光有语言支持不会上色，所以要带上这一项。
 */
export function syntaxHighlightingExtension() {
  return syntaxHighlighting(syntaxStyle);
}
