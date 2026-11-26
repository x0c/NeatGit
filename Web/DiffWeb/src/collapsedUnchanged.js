// 「只看变更」：折叠未变更区域。
// 不用库自带的折叠（点一下整段全展开），这里自己记录每个未变更区间「上下各已展开多少行」；
// 并排视图的左右两栏共用同一份状态，所以折叠进度天然同步，单栏视图用同一套逻辑。
import { EditorView, Decoration, WidgetType } from '@codemirror/view';
import { StateField, StateEffect, RangeSetBuilder } from '@codemirror/state';
import { getChunks } from '@codemirror/merge';

// 上下各保留的行数、可折叠的最少行数、点击一次展开的行数（与现有页面一致）。
export const CONTEXT_LINE_COUNT = 3;
export const MINIMUM_HIDDEN_LINE_COUNT = 3;
export const REVEAL_LINE_COUNT = 20;

/**
 * 找出可折叠的未变更区间。
 * changedLineRanges：本侧改动行的范围，按先后排列，行号从 1 起、两端都包含。
 * 规则：改动块之间（以及全文开头、结尾）连续未变更的行，去掉上下各 CONTEXT_LINE_COUNT 行后，
 * 剩余行数不少于 MINIMUM_HIDDEN_LINE_COUNT 才折叠。全文没有任何改动时不折叠。
 */
export function computeUnchangedGaps(changedLineRanges, totalLines) {
  const gaps = [];
  if (changedLineRanges.length === 0) {
    return gaps;
  }
  let previousLastLine = 0;
  for (let index = 0; ; index++) {
    const range = index < changedLineRanges.length ? changedLineRanges[index] : null;
    const fromLine = index ? previousLastLine + 1 + CONTEXT_LINE_COUNT : 1;
    const toLine = range ? range.fromLine - 1 - CONTEXT_LINE_COUNT : totalLines;
    if (toLine - fromLine + 1 >= MINIMUM_HIDDEN_LINE_COUNT) {
      gaps.push({ fromLine, toLine });
    }
    if (!range) {
      break;
    }
    previousLastLine = range.toLine;
  }
  return gaps;
}

/**
 * 区间里仍然折叠着的行；不足 MINIMUM_HIDDEN_LINE_COUNT 行时返回 null，表示整段展开。
 * reveal：{ top, bottom }，上下各已经展开的行数。
 */
export function hiddenRange(gap, reveal) {
  const top = Math.max(0, reveal?.top ?? 0);
  const bottom = Math.max(0, reveal?.bottom ?? 0);
  const fromLine = gap.fromLine + top;
  const toLine = gap.toLine - bottom;
  const hidden = toLine - fromLine + 1;
  return hidden >= MINIMUM_HIDDEN_LINE_COUNT ? { fromLine, toLine, hidden } : null;
}

/** 点击一次之后新的展开记录：向上（top）或向下（bottom）多展开 REVEAL_LINE_COUNT 行。 */
export function nextReveal(reveal, direction) {
  return {
    top: (reveal?.top ?? 0) + (direction === 'top' ? REVEAL_LINE_COUNT : 0),
    bottom: (reveal?.bottom ?? 0) + (direction === 'bottom' ? REVEAL_LINE_COUNT : 0)
  };
}

/** 两侧共用的一份折叠状态：revision 变化时通知各视图重算。 */
export function createCollapsedState() {
  return { revision: 0, reveals: new Map(), onChange: null };
}

/** 展开某个区间的若干行，并通知所有视图重算。 */
export function revealCollapsedLines(collapsedState, gapIndex, direction) {
  collapsedState.reveals.set(gapIndex, nextReveal(collapsedState.reveals.get(gapIndex), direction));
  collapsedState.revision += 1;
  collapsedState.onChange?.();
}

const setCollapseRevision = StateEffect.define();
const collapseRevision = StateField.define({
  create: () => 0,
  update(value, transaction) {
    let next = value;
    for (const effect of transaction.effects) {
      if (effect.is(setCollapseRevision)) {
        next = effect.value;
      }
    }
    return next;
  }
});

/** 折叠状态变化后派发给视图的事务效果，由页面在 onChange 里转给当前所有视图。 */
export function collapseSyncEffect(collapsedState) {
  return setCollapseRevision.of(collapsedState.revision);
}

function buildCollapsedDecorations(state, collapsedState) {
  const info = getChunks(state);
  if (!info) {
    return Decoration.none;
  }
  const isOriginalSide = info.side === 'a';
  const doc = state.doc;
  const changedLineRanges = [];
  for (const chunk of info.chunks) {
    const from = isOriginalSide ? chunk.fromA : chunk.fromB;
    const firstLine = doc.lineAt(from).number;
    // 本侧没有行的改动块（对面的纯新增 / 纯删除）记成一个点：它前面的区间在它上方 3 行处收口，
    // 后面的区间从它下方 3 行处开始，这样被删除的内容不会折进未变更区域里。
    const lastLine = from === (isOriginalSide ? chunk.toA : chunk.toB) ? firstLine - 1 : doc.lineAt(isOriginalSide ? chunk.endA : chunk.endB).number;
    changedLineRanges.push({ fromLine: firstLine, toLine: lastLine });
  }

  const builder = new RangeSetBuilder();
  computeUnchangedGaps(changedLineRanges, doc.lines).forEach((gap, index) => {
    const hidden = hiddenRange(gap, collapsedState.reveals.get(index));
    if (hidden) {
      const decoration = Decoration.replace({
        block: true,
        widget: new CollapsedLinesWidget(collapsedState, index, hidden.hidden)
      });
      builder.add(doc.line(hidden.fromLine).from, doc.line(hidden.toLine).to, decoration);
    }
  });
  return builder.finish();
}

/** 折叠扩展：挂在一个可以重新配置的隔间里，开关「只看变更」时不重建视图。 */
export function collapsedUnchanged(collapsedState) {
  return [
    collapseRevision.init(() => collapsedState.revision),
    EditorView.decorations.compute([collapseRevision], (state) =>
      buildCollapsedDecorations(state, collapsedState)
    )
  ];
}

function createArrow(pointUpward) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'ng-collapsed-arrow');
  svg.setAttribute('viewBox', '0 0 10 6');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', pointUpward ? 'M1 5 L5 1 L9 5' : 'M1 1 L5 5 L9 1');
  svg.appendChild(path);
  return svg;
}

/** 占位行：一个按钮，左半边向上展开、右半边向下展开，每次 REVEAL_LINE_COUNT 行。 */
class CollapsedLinesWidget extends WidgetType {
  constructor(collapsedState, gapIndex, hiddenLineCount) {
    super();
    this.collapsedState = collapsedState;
    this.gapIndex = gapIndex;
    this.hiddenLineCount = hiddenLineCount;
  }

  eq(other) {
    return (
      other.collapsedState === this.collapsedState &&
      other.gapIndex === this.gapIndex &&
      other.hiddenLineCount === this.hiddenLineCount
    );
  }

  toDOM() {
    const { collapsedState, gapIndex, hiddenLineCount } = this;
    const description = `展开 ${REVEAL_LINE_COUNT} 行未变更内容，还有 ${hiddenLineCount} 行未展开`;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'ng-collapsedLines';
    button.setAttribute('aria-label', description);
    button.title = description;
    button.appendChild(createArrow(true));
    const label = document.createElement('span');
    label.className = 'ng-collapsed-text';
    label.textContent = `${hiddenLineCount} 行未变更`;
    button.appendChild(label);
    button.appendChild(createArrow(false));
    button.addEventListener('click', (event) => {
      // 鼠标点在左半边向上展开、右半边向下展开；键盘触发（没有坐标）时向下展开。
      const bounds = button.getBoundingClientRect();
      const upward = event.detail > 0 && event.clientX - bounds.left < bounds.width / 2;
      revealCollapsedLines(collapsedState, gapIndex, upward ? 'top' : 'bottom');
    });
    // 焦点在按钮上时，按键交给按钮自己，不要被编辑器的光标移动抢走；Tab 仍然照常移出。
    button.addEventListener('keydown', (event) => {
      if (event.key !== 'Tab') {
        event.stopPropagation();
      }
    });
    return button;
  }

  ignoreEvent() {
    return true;
  }

  get estimatedHeight() {
    return 27;
  }
}
