// 差异算法：先做行级比对，再对两侧都有内容的小段做字符级细化。
//
// 为什么不直接用库自带的差异（本机实测）：
// - 库按字符比对，范围一大就靠「整段标成改动」兜底：默认精度参数下，1 万行、仅 21 行改动的样本被
//   整份标成改动；调大精度参数后，约 2.7 MB、散布 30 余行改动的样本又被整份标成改动；再调大，
//   约 2.7 MB 两侧完全无关的样本要算 24 秒。
// - 拿它比对「每行一个编号」的短串也不行：它追求观感而非最小改动，行内容大量重复时会把改动范围
//   错位（20 种行内容重复 1 万行、改 21 行的样本，被标出上千行）。
// 所以行级比对在这里自己实现：求最小改动，结果只取决于内容，不受重复度影响；万行文件几毫秒到几十毫秒。
import { Change, presentableDiff } from '@codemirror/merge';
import { Text } from '@codemirror/state';

// 与编辑器默认的分行规则保持一致。
const LINE_BREAK = /\r\n?|\n/;

// 字符级细化的精度参数：取 5 万，配 300 毫秒耗时上限兜底。细化只发生在两侧都有内容的小段上，
// 正常提交都在几毫秒内；耗时到顶就退化为粗略结果，影响的只是这一段的行内高亮，行级结果不受影响。
export const CHARACTER_DIFF_CONFIG = { scanLimit: 50000, timeout: 300 };

// 字符级细化只对「两侧都有内容、规模不大」的替换段做：超过这个长度或行数的段本来就是整段改写，
// 行内高亮没有意义，细化反而可能让页面卡住数秒（本机实测约 1 MB 的整段改写要 4 秒多）。
const REFINEMENT_LENGTH_LIMIT = 100000;
const REFINEMENT_LINE_LIMIT = 400;
// 整份差异里留给细化的总时间。行内容几乎全变的文件会有成百上千个替换段，逐段细化会累加到几十秒；
// 超出预算后其余段落整体记为改动（行级结果不受影响）。
const REFINEMENT_TIME_BUDGET_MS = 800;

// 行级比对的工作量上限（按处理的步数计）。正常文件远用不到；两侧完全无关的十几万行文件才会触顶，
// 触顶后剩余部分整体记为改动。
const LINE_DIFF_STEP_LIMIT = 300000000;

// 差异视图用的配置：库自带的精度参数，加上这里的行级预比对。
export function createDiffConfig() {
  return { ...CHARACTER_DIFF_CONFIG, override: computeDiff };
}

/**
 * 行级最小差异（Myers 算法的线性空间版本：分治找「中位蛇」）。
 * a、b 是每行一个编号的序列；返回改动范围列表，行序号从 0 起、左闭右开，按先后排列。
 */
export function diffLineIds(a, b) {
  const changes = [];
  let steps = 0;
  let exhausted = false;

  // 返回一个分点 [x, y]（相对下标）：把问题拆成左右两个更小的子问题。
  const middleSnake = (a0, a1, b0, b1) => {
    const n = a1 - a0;
    const m = b1 - b0;
    const delta = n - m;
    const odd = ((delta % 2) + 2) % 2 === 1;
    const maxD = (n + m + 1) >> 1;
    const offset = maxD + 1;
    const forward = new Int32Array(2 * maxD + 3);
    const backward = new Int32Array(2 * maxD + 3);
    forward[offset + 1] = 0;
    backward[offset + 1] = 0;
    for (let d = 0; d <= maxD; d += 1) {
      steps += 2 * d + 2;
      if (steps > LINE_DIFF_STEP_LIMIT) {
        exhausted = true;
      }
      // 正向：每条对角线上能走到的最远位置。
      for (let k = -d; k <= d; k += 2) {
        let x;
        if (k === -d || (k !== d && forward[offset + k - 1] < forward[offset + k + 1])) {
          x = forward[offset + k + 1];
        } else {
          x = forward[offset + k - 1] + 1;
        }
        let y = x - k;
        while (x < n && y < m && a[a0 + x] === b[b0 + y]) {
          x += 1;
          y += 1;
        }
        forward[offset + k] = x;
        // 与上一轮反向路径相遇：找到分点。
        // 正向对角线 k 对应的反向对角线是 delta - k。
        if (odd && k >= delta - (d - 1) && k <= delta + (d - 1) && x + backward[offset + delta - k] >= n) {
          return [x, y];
        }
      }
      // 反向：从末尾往回走。
      for (let k = -d; k <= d; k += 2) {
        let x;
        if (k === -d || (k !== d && backward[offset + k - 1] < backward[offset + k + 1])) {
          x = backward[offset + k + 1];
        } else {
          x = backward[offset + k - 1] + 1;
        }
        let y = x - k;
        while (x < n && y < m && a[a1 - 1 - x] === b[b1 - 1 - y]) {
          x += 1;
          y += 1;
        }
        backward[offset + k] = x;
        // 反向对角线 k 对应的正向对角线是 delta - k，本轮正向只覆盖到 ±d。
        if (!odd && k >= delta - d && k <= delta + d) {
          const forwardX = forward[offset + delta - k];
          if (x + forwardX >= n) {
            return [forwardX, forwardX - (delta - k)];
          }
        }
      }
    }
    return [0, 0];
  };

  const walk = (a0, a1, b0, b1) => {
    // 先去掉两侧完全相同的前缀、后缀。
    while (a0 < a1 && b0 < b1 && a[a0] === b[b0]) {
      a0 += 1;
      b0 += 1;
    }
    while (a0 < a1 && b0 < b1 && a[a1 - 1] === b[b1 - 1]) {
      a1 -= 1;
      b1 -= 1;
    }
    if (a0 === a1 && b0 === b1) {
      return;
    }
    if (exhausted || a0 === a1 || b0 === b1) {
      changes.push({ a0, a1, b0, b1 });
      return;
    }
    const [x, y] = middleSnake(a0, a1, b0, b1);
    if ((x === 0 && y === 0) || (x === a1 - a0 && y === b1 - b0)) {
      // 理论上不会到这里；真遇到就把当前段整体记为改动，保证能结束。
      changes.push({ a0, a1, b0, b1 });
      return;
    }
    walk(a0, a0 + x, b0, b0 + y);
    walk(a0 + x, a1, b0 + y, b1);
  };

  walk(0, a.length, 0, b.length);

  // 「删一行、紧挨着再增一行」是改动一行的两种写法，按最小差异可能被拆成前后相接的两段；
  // 这里并成一段「替换」，后面才会对它做字符级细化（行内高亮）。
  const merged = [];
  for (const range of changes) {
    const previous = merged[merged.length - 1];
    if (previous && previous.a1 === range.a0 && previous.b1 === range.b0) {
      previous.a1 = range.a1;
      previous.b1 = range.b1;
    } else {
      merged.push({ a0: range.a0, a1: range.a1, b0: range.b0, b1: range.b1 });
    }
  }
  return merged;
}

// 给出差异视图用的差异范围（两侧全文的字符位置）。
export function computeDiff(originalText, modifiedText) {
  const originalLines = Text.of(originalText.split(LINE_BREAK));
  const modifiedLines = Text.of(modifiedText.split(LINE_BREAK));
  // 每一行映射成一个编号，相同的行编号相同。
  const lineIds = new Map();
  const toLineIds = (lines) => {
    const ids = new Int32Array(lines.lines);
    for (let number = 1; number <= lines.lines; number += 1) {
      const text = lines.line(number).text;
      let id = lineIds.get(text);
      if (id === undefined) {
        id = lineIds.size;
        lineIds.set(text, id);
      }
      ids[number - 1] = id;
    }
    return ids;
  };
  const lineChanges = diffLineIds(toLineIds(originalLines), toLineIds(modifiedLines));

  // 第 lineIndex 行（从 0 起）首字符的位置；超出末行时取全文末尾。
  // 差异范围带上行尾换行，这样「整行新增 / 删除」的范围正好落在行边界上。
  const boundaryOffset = (lines, text, lineIndex) =>
    lineIndex < lines.lines ? lines.line(lineIndex + 1).from : text.length;

  const changes = [];
  // 第一次需要细化时才开始计时。
  let refinementDeadline = Infinity;
  for (const range of lineChanges) {
    const fromLineA = range.a0;
    const toLineA = range.a1;
    const fromLineB = range.b0;
    const toLineB = range.b1;
    let fromA = boundaryOffset(originalLines, originalText, fromLineA);
    let toA = boundaryOffset(originalLines, originalText, toLineA);
    let fromB = boundaryOffset(modifiedLines, modifiedText, fromLineB);
    let toB = boundaryOffset(modifiedLines, modifiedText, toLineB);

    // 一侧没有任何内容（纯新增 / 纯删除，或只剩一个空行）时不需要细化。
    const emptyOnA = fromLineA === toLineA || toA === fromA;
    const emptyOnB = fromLineB === toLineB || toB === fromB;
    // 范围终点按「下一行行首」记；全文末尾且没有换行符时，那里并不是行首。
    const endsAtLineStart = (lines, lineIndex) => lineIndex < lines.lines;
    const endsAfterLine = (lines, text, lineNumber) => lineNumber > 0 && lines.line(lineNumber).to < text.length;
    // 纯新增 / 纯删除且终点不在行首时：把起点改记在两侧「上一行」的行尾，也就是把分隔用的换行符算进
    // 改动。库按字符位置划分改动块，位于行尾的空范围会落到下一行行首，这样改动块在没有改动的一侧
    // 才是空的；否则在全文末尾追加一行会把原文末尾那个空行也标成删除。
    if (emptyOnA && !endsAtLineStart(modifiedLines, toLineB) && endsAfterLine(originalLines, originalText, fromLineA) && endsAfterLine(modifiedLines, modifiedText, fromLineB)) {
      fromA = toA = originalLines.line(fromLineA).to;
      fromB = modifiedLines.line(fromLineB).to;
    } else if (emptyOnB && !endsAtLineStart(originalLines, toLineA) && endsAfterLine(modifiedLines, modifiedText, fromLineB) && endsAfterLine(originalLines, originalText, fromLineA)) {
      fromB = toB = modifiedLines.line(fromLineB).to;
      fromA = originalLines.line(fromLineA).to;
    }

    // 已知局限（库的数据模型所致）：上一行后面没有换行符时只能按行首记，库会把全文末尾的空范围
    // 归到末行。所以原文末行没有换行符时「末尾追加一行」会把原文末行也标成删除；修改后末行没有
    // 换行符时「删掉末尾几行」会把修改后保留的末行也标成新增。文件以换行符结尾时没有这个问题。
    const tooLarge =
      toA - fromA > REFINEMENT_LENGTH_LIMIT ||
      toB - fromB > REFINEMENT_LENGTH_LIMIT ||
      toLineA - fromLineA > REFINEMENT_LINE_LIMIT ||
      toLineB - fromLineB > REFINEMENT_LINE_LIMIT;
    if (emptyOnA || emptyOnB || tooLarge || Date.now() > refinementDeadline) {
      // 纯新增、纯删除或整段改写：整段就是一个差异，不做细化。
      changes.push(new Change(fromA, toA, fromB, toB));
      continue;
    }

    // 两侧都有内容：只在这一小段里做字符级细化，得到行内高亮需要的精确范围。
    if (refinementDeadline === Infinity) {
      refinementDeadline = Date.now() + REFINEMENT_TIME_BUDGET_MS;
    }
    const refined = presentableDiff(
      originalText.slice(fromA, toA),
      modifiedText.slice(fromB, toB),
      CHARACTER_DIFF_CONFIG
    );
    if (refined.length === 0) {
      changes.push(new Change(fromA, toA, fromB, toB));
      continue;
    }
    for (const part of refined) {
      changes.push(new Change(fromA + part.fromA, fromA + part.toA, fromB + part.fromB, fromB + part.toB));
    }
  }
  return changes;
}
