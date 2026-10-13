// MARK: - Mermaid 语法预归一化脚本

function quoteIfNeeded(s) {
  const t = s.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t;
  }
  return '"' + t.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

// 语法预归一化层：
// 针对 Mermaid 各子图解析器（Jison / Langium）对中文、连字符 '-'、百分号 '%'、括号或未加引号文本的严苛词法限制，
// 在进入 mermaid.render 前进行无损语法归正，消除大模型生成标准语法却触发 "语法未闭合或暂不可预览" 的问题。
function normalizeMermaidSource(raw) {
  if (!raw) return raw;
  const lines = raw.split(/\r?\n/);
  let firstContentIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t || t.startsWith('%%')) continue;
    if (t === '---') {
      i++;
      while (i < lines.length && lines[i].trim() !== '---') i++;
      continue;
    }
    firstContentIdx = i;
    break;
  }
  if (firstContentIdx === -1) return raw;
  const header = lines[firstContentIdx].trim();

  // 1. requirementDiagram: Jison unqString 词法规则禁止包含 '-' / ':' / ',' / '=' / '<' / '>'（如 id: REQ-101 会直接报错）
  if (/^requirementDiagram\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const attrMatch = line.match(/^(\s*(?:id|text|type|docref)\s*:\s*)(.+?)(\s*)$/i);
      if (attrMatch) {
        return attrMatch[1] + quoteIfNeeded(attrMatch[2]) + attrMatch[3];
      }
      const declMatch = line.match(/^(\s*(?:requirement|functionalRequirement|interfaceRequirement|performanceRequirement|physicalRequirement|designConstraint|element)\s+)([^\s"{]+)(\s*(?::::[^\s{]+)?\s*\{.*)$/i);
      if (declMatch && /[-:,=<>]/.test(declMatch[2])) {
        return declMatch[1] + quoteIfNeeded(declMatch[2]) + declMatch[3];
      }
      const relMatch = line.match(/^(\s*)([^\s"<-]+)(\s+(?:-\s*(?:contains|copies|derives|satisfies|verifies|refines|traces)\s*->|<-\s*(?:contains|copies|derives|satisfies|verifies|refines|traces)\s*-)\s+)([^\s"]+)(\s*)$/i);
      if (relMatch) {
        const lhs = /[-:,=<>]/.test(relMatch[2]) ? quoteIfNeeded(relMatch[2]) : relMatch[2];
        const rhs = /[-:,=<>]/.test(relMatch[4]) ? quoteIfNeeded(relMatch[4]) : relMatch[4];
        return relMatch[1] + lhs + relMatch[3] + rhs + relMatch[5];
      }
      return line;
    }).join('\n');
  }

  // 2. xychart / xychart-beta: 未加引号的标题或坐标轴若含 '%' / '/' / '$' 等字符会触发词法错误，且空格会被吞掉
  if (/^xychart(?:-beta)?\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const titleMatch = line.match(/^(\s*title\s+)(.+?)(\s*)$/i);
      if (titleMatch) {
        return titleMatch[1] + quoteIfNeeded(titleMatch[2]) + titleMatch[3];
      }
      const bandMatch = line.match(/^(\s*x-axis\s+)(?:(.+?)\s+)?(\[[^\]]*\])(\s*)$/i);
      if (bandMatch) {
        const axisTitle = bandMatch[2] ? quoteIfNeeded(bandMatch[2]) + ' ' : '';
        const inner = bandMatch[3].slice(1, -1).split(',').map(item => {
          const t = item.trim();
          if (!t) return item;
          if (/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/.test(t)) return t;
          return quoteIfNeeded(t);
        }).join(', ');
        return bandMatch[1] + axisTitle + '[' + inner + ']' + bandMatch[4];
      }
      const rangeMatch = line.match(/^(\s*[xy]-axis\s+)(.+?)(\s+[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*-->\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*)$/i);
      if (rangeMatch) {
        return rangeMatch[1] + quoteIfNeeded(rangeMatch[2]) + rangeMatch[3];
      }
      const titleOnlyAxis = line.match(/^(\s*[xy]-axis\s+)(?!\[)(.+?)(\s*)$/i);
      if (titleOnlyAxis && !/-->/.test(titleOnlyAxis[2])) {
        return titleOnlyAxis[1] + quoteIfNeeded(titleOnlyAxis[2]) + titleOnlyAxis[3];
      }
      return line;
    }).join('\n');
  }

  // 3. packet / packet-beta: 报文段冒号后的描述必须为双引号字符串
  if (/^packet(?:-beta)?\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const blkMatch = line.match(/^(\s*(?:\d+(?:\s*-\s*\d+)?|\+\d+)\s*:\s*)(.+?)(\s*)$/);
      if (blkMatch) {
        return blkMatch[1] + quoteIfNeeded(blkMatch[2]) + blkMatch[3];
      }
      return line;
    }).join('\n');
  }

  // 4. radar-beta: Langium 要求 axis/curve 标识符为 ASCII [\w-]+，且 [...] 内标签必须加引号
  if (/^radar-beta\b/i.test(header)) {
    let axisCounter = 0;
    let curveCounter = 0;
    const axisIdMap = new Map();
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const axisMatch = line.match(/^(\s*axis\s+)(.+?)(\s*)$/i);
      if (axisMatch) {
        const items = axisMatch[2].split(',').map(rawItem => {
          const item = rawItem.trim();
          if (!item) return rawItem;
          const idLabelMatch = item.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*\[(.*)\]$/);
          if (idLabelMatch) {
            return `${idLabelMatch[1]}[${quoteIfNeeded(idLabelMatch[2])}]`;
          }
          if (/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(item)) {
            return item;
          }
          const cleanLabel = item.replace(/^["']|["']$/g, '');
          const genId = `ax_${++axisCounter}`;
          axisIdMap.set(cleanLabel, genId);
          return `${genId}[${quoteIfNeeded(cleanLabel)}]`;
        });
        return axisMatch[1] + items.join(', ') + axisMatch[3];
      }
      const curveMatch = line.match(/^(\s*curve\s+)(.+?)(\s*\{)(.*)(\}\s*)$/i);
      if (curveMatch) {
        const rawCurve = curveMatch[2].trim();
        let normCurve = rawCurve;
        const idLabelMatch = rawCurve.match(/^([A-Za-z0-9_][A-Za-z0-9_-]*)\s*\[(.*)\]$/);
        if (idLabelMatch) {
          normCurve = `${idLabelMatch[1]}[${quoteIfNeeded(idLabelMatch[2])}]`;
        } else if (!/^[A-Za-z0-9_][A-Za-z0-9_-]*$/.test(rawCurve)) {
          const cleanLabel = rawCurve.replace(/^["']|["']$/g, '');
          normCurve = `cv_${++curveCounter}[${quoteIfNeeded(cleanLabel)}]`;
        }
        let body = curveMatch[4];
        if (body.includes(':')) {
          body = body.split(',').map(entry => {
            const kv = entry.split(':');
            if (kv.length === 2) {
              const k = kv[0].trim().replace(/^["']|["']$/g, '');
              const mapped = axisIdMap.get(k) || k;
              return `${mapped}: ${kv[1].trim()}`;
            }
            return entry;
          }).join(', ');
        }
        return curveMatch[1] + normCurve + curveMatch[3] + body + curveMatch[5];
      }
      return line;
    }).join('\n');
  }

  // 5. erDiagram: 实体属性行末尾未加引号的注释自动补双引号
  if (/^erDiagram\b/i.test(header)) {
    let inBlock = false;
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const trimmed = line.trim();
      if (!inBlock && trimmed.endsWith('{') && !trimmed.includes(':')) {
        inBlock = true;
        return line;
      }
      if (inBlock && trimmed === '}') {
        inBlock = false;
        return line;
      }
      if (inBlock && trimmed && !trimmed.startsWith('%%')) {
        const m = line.match(/^(\s*\S+\s+\S+)(\s+(?:(?:PK|FK|UK)(?:\s*,\s*(?:PK|FK|UK))*))?(\s+)(.+?)(\s*)$/i);
        if (m) {
          const comment = m[4].trim();
          if (comment && !/^(?:PK|FK|UK)$/i.test(comment) && !(comment.startsWith('"') && comment.endsWith('"'))) {
            return m[1] + (m[2] || '') + m[3] + quoteIfNeeded(comment) + m[5];
          }
        }
      }
      return line;
    }).join('\n');
  }

  // 6. pie: 切片名称未加引号时自动补双引号
  if (/^pie\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('%%') || /^(?:title|accTitle|accDescr)\b/i.test(trimmed)) return line;
      const m = line.match(/^(\s*)([^":]+?)(\s*:\s*-?\d+(?:\.\d+)?\s*)$/);
      if (m) {
        return m[1] + quoteIfNeeded(m[2]) + m[3];
      }
      return line;
    }).join('\n');
  }

  // 7. gitGraph: 分支名含中文或特殊字符时自动补双引号
  if (/^gitGraph\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const m = line.match(/^(\s*(?:branch|checkout|switch|merge)\s+)([^\s"]+)(\s+.*|\s*)$/i);
      if (m && !/^[A-Za-z0-9_][-\./A-Za-z0-9_]*[A-Za-z0-9_-]$|^[A-Za-z0-9_]$/.test(m[2])) {
        return m[1] + quoteIfNeeded(m[2]) + m[3];
      }
      return line;
    }).join('\n');
  }

  // 8. treemap-beta / treemap: 节点名称未加引号时自动补双引号
  if (/^treemap(?:-beta)?\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('%%') || /^(?:title|accTitle|accDescr|classDef)\b/i.test(trimmed)) return line;
      const m = line.match(/^(\s*)([^":\n]+?)(\s*(?::\s*[\d.,_]+)?\s*(?::::[A-Za-z_]\w*)?\s*)$/);
      if (m && !m[2].trim().startsWith("'") && !m[2].trim().startsWith('"')) {
        return m[1] + quoteIfNeeded(m[2]) + m[3];
      }
      return line;
    }).join('\n');
  }

  // 9. C4 系列图表 (C4Context / C4Container / C4Component / C4Dynamic / C4Deployment):
  //    - Jison 语法仅允许 *_Boundary / Boundary / Deployment_Node / Node 后接 '{ ... }'，若对 Container / System 等加 '{' 会报错；
  //    - 反之，Deployment_Node / Node / *_Boundary 在语法中必须后接非空 '{ ... }' 且不进入形状表 Yl（无法被 Rel 连线），
  //      若作为不带 '{ ... }' 的叶子节点出现，需归正为 Container 叶子形状。
  if (/^C4(?:Context|Container|Component|Dynamic|Deployment)\b/i.test(header)) {
    const result = [...lines];
    for (let i = firstContentIdx + 1; i < result.length; i++) {
      const line = result[i];
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('%%')) continue;

      // 处理单行空花括号块（如 Deployment_Node(...) {}）
      const emptyInlineMatch = line.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*\(.*\))\s*\{\s*\}\s*$/);
      if (emptyInlineMatch) {
        result[i] = emptyInlineMatch[1] + 'Container' + emptyInlineMatch[3];
        continue;
      }

      const m = line.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*\(.*\))(\s*)(\{?\s*)$/);
      if (!m) continue;
      const [, indent, kw, argsPart, midSpace, bracePart] = m;
      let hasBrace = bracePart.startsWith('{');
      if (!hasBrace) {
        for (let j = i + 1; j < result.length; j++) {
          const nt = result[j].trim();
          if (!nt || nt.startsWith('%%')) continue;
          if (nt.startsWith('{')) {
            hasBrace = true;
          }
          break;
        }
      }

      if (hasBrace) {
        let newKw = kw;
        if (/^Container(?:Db|Queue)?(?:_Ext)?$/i.test(kw)) {
          newKw = 'Container_Boundary';
        } else if (/^System(?:Db|Queue)?(?:_Ext)?$/i.test(kw)) {
          newKw = 'System_Boundary';
        } else if (/^Enterprise$/i.test(kw)) {
          newKw = 'Enterprise_Boundary';
        } else if (/^(?:Component(?:Db|Queue)?(?:_Ext)?|Person(?:_Ext)?)$/i.test(kw)) {
          newKw = 'Boundary';
        }
        if (newKw !== kw) {
          result[i] = indent + newKw + argsPart + midSpace + bracePart;
        }
      } else {
        if (/^(?:Deployment_Node|Node|Node_L|Node_R|(?:Container|System|Enterprise)_Boundary|Boundary)$/i.test(kw)) {
          result[i] = indent + 'Container' + argsPart + midSpace + bracePart;
        }
      }
    }
    return result.join('\n');
  }

  // 10. mindmap: Jison 词法规则 1 (/^(?:mindmap\b)/i) 优先级高于普通节点规则 19 (NODE_ID)，
  //     当缩进子节点裸文本以 "mindmap" 开头（如 "mindmap 思维导图"）时会被误判为图表头关键字而语法报错；
  //     在缩进与文本之间注入零宽空格 \u200B，既不改变 SPACELIST 缩进长度，又可避开关键字抢占并保留默认无框样式。
  if (/^mindmap\b/i.test(header)) {
    return lines.map((line, idx) => {
      if (idx <= firstContentIdx) return line;
      return line.replace(/^(\s*)(mindmap\b)/i, '$1\u200B$2');
    }).join('\n');
  }

  return raw;
}
