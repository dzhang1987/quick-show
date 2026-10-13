// MARK: - Mermaid WebKit 通信桥梁与动态渲染调度器

let renderCounter = 0;
let renderTimer = null;
let lastReportedHeight = 0;
let pendingRenderArgs = null;

function reportContainerHeight() {
  const container = document.getElementById('container');
  const svgEl = container ? container.querySelector('svg') : null;
  if (!container || !svgEl) return;

  const svgRect = svgEl.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  let height = Math.ceil(Math.max(containerRect.height, svgRect.height + 12));
  if (!height || height <= 0) {
    height = Math.ceil(container.scrollHeight);
  }
  const finalHeight = Math.max(height, 24);
  if (Math.abs(finalHeight - lastReportedHeight) >= 1) {
    lastReportedHeight = finalHeight;
    window.webkit.messageHandlers.mermaidBridge.postMessage({
      type: 'rendered',
      height: finalHeight
    });
  }
}

const resizeObserver = new ResizeObserver(() => {
  if (pendingRenderArgs && document.body.clientWidth >= 10) {
    const args = pendingRenderArgs;
    pendingRenderArgs = null;
    doRenderDiagram(args.code, args.isDark, args.look, args.theme);
    return;
  }
  requestAnimationFrame(reportContainerHeight);
});

window.addEventListener('DOMContentLoaded', () => {
  const container = document.getElementById('container');
  if (container) resizeObserver.observe(container);
  resizeObserver.observe(document.body);
});

function updateCanvasContrastCSS(isDark, theme) {
  const styleEl = document.getElementById('qs-canvas-contrast');
  if (!styleEl) return;

  const isThemeBuiltForDark = (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark' || theme === 'redux-dark-color');
  const canvasFg = isDark ? '#F1F5F9' : '#1E293B';
  const canvasTitleFg = isDark ? '#F8FAFC' : '#0F172A';
  const canvasLine = isDark ? '#CBD5E1' : '#475569';
  const canvasSubtleLine = isDark ? '#94A3B8' : '#64748B';
  const canvasHalo = isDark ? 'rgba(24, 28, 38, 0.88)' : 'rgba(248, 250, 252, 0.9)';

  // 1. 基础跨图表补齐层（始终生效）：
  //    针对 Mermaid 源码中硬编码 #444444 / #666 / black / lightgrey、将 SVG text 误写为 color 而非 fill、
  //    或使用 mix-blend-mode: multiply 导致暗色背景下连线/文字消失的图表进行统一归正。
  let css = `
    /* C4 架构图 (C4Context / C4Container / C4Component / C4Dynamic / C4Deployment) */
    svg[aria-roledescription="c4"] [stroke="#444444"] {
      stroke: ${canvasLine} !important;
    }
    svg[aria-roledescription="c4"] line[stroke="#444444"],
    svg[aria-roledescription="c4"] path[stroke="#444444"] {
      stroke-width: 1.5px !important;
    }
    svg[aria-roledescription="c4"] text[fill="#444444"],
    svg[aria-roledescription="c4"] tspan[fill="#444444"] {
      fill: ${canvasFg} !important;
      paint-order: stroke fill;
      stroke: ${canvasHalo};
      stroke-width: 3.5px;
      stroke-linejoin: round;
    }
    svg[aria-roledescription="c4"] > text {
      fill: ${canvasTitleFg} !important;
      font-size: 16px !important;
      font-weight: 600 !important;
    }
    svg[aria-roledescription="c4"] defs marker path {
      fill: ${canvasLine} !important;
      stroke: ${canvasLine} !important;
    }
    svg[aria-roledescription="c4"] .c4-shape .label text,
    svg[aria-roledescription="c4"] .c4-shape .label tspan {
      fill: #FFFFFF !important;
      paint-order: stroke fill;
      stroke: rgba(15, 23, 42, 0.68);
      stroke-width: 2.5px;
      stroke-linejoin: round;
    }

    /* Packet 报文结构图与 TreeView 树形视图（源码未随主题覆盖时默认回退为 black 纯黑字） */
    svg .packetTitle,
    svg .treeView-title {
      fill: ${canvasTitleFg} !important;
      font-weight: 600;
    }
    svg .packetLabel,
    svg .packetByte,
    svg .treeView-node-label,
    svg .treeView-node-dir {
      fill: ${canvasFg} !important;
    }
    svg .packetBlock {
      stroke: ${canvasSubtleLine} !important;
      fill: ${isDark ? 'rgba(255, 255, 255, 0.07)' : 'rgba(15, 23, 42, 0.04)'} !important;
    }
    svg[aria-roledescription="treeView"] path,
    svg[aria-roledescription="treeView"] line {
      stroke: ${canvasSubtleLine} !important;
    }

    /* Radar 雷达图（源码误用 color 而非 SVG fill，导致标题/轴标签/图例在暗黑下全黑） */
    svg .radarTitle {
      fill: ${canvasTitleFg} !important;
      font-weight: 600;
    }
    svg .radarAxisLabel,
    svg .radarLegendText {
      fill: ${canvasFg} !important;
    }
    svg .radarAxisLine {
      stroke: ${canvasSubtleLine} !important;
    }
    svg .radarGraticule {
      stroke: ${isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(15, 23, 42, 0.16)'} !important;
      fill: ${isDark ? 'rgba(255, 255, 255, 0.03)' : 'rgba(15, 23, 42, 0.02)'} !important;
    }

    /* Sankey 桑基图（源码 mix-blend-mode: multiply 在深色毛玻璃底上会正片叠底变黑消失） */
    svg .links .link {
      mix-blend-mode: ${isDark ? 'normal' : 'multiply'} !important;
      stroke-opacity: ${isDark ? '0.62' : '0.5'} !important;
    }
    svg .node-labels text {
      fill: ${canvasTitleFg} !important;
    }

    /* Architecture 架构图（源码未给服务/分组/连线文本设置 fill） */
    svg .architecture-services text,
    svg .architecture-services tspan,
    svg .architecture-groups text,
    svg .architecture-groups tspan,
    svg .architecture-edges text,
    svg .architecture-edges tspan {
      fill: ${canvasFg} !important;
    }
    svg .architecture-groups rect.node-bkg,
    svg .architecture-services path.node-bkg {
      stroke: ${canvasSubtleLine} !important;
    }

    /* GitGraph 提交图（源码将 commit-id/msg 硬编码为 lightgrey，亮色下看不清） */
    svg .commit-id,
    svg .commit-msg {
      fill: ${canvasFg} !important;
      color: ${canvasFg} !important;
    }
    svg .commit-label {
      fill: ${canvasTitleFg} !important;
    }
    svg .commit-label-bkg {
      fill: ${isDark ? 'rgba(30, 41, 59, 0.85)' : 'rgba(241, 245, 249, 0.9)'} !important;
      opacity: 0.92 !important;
    }

    /* Journey 用户旅程图（源码将画布任务虚线、底轴箭头与左侧角色名硬编码为 #666） */
    svg[aria-roledescription="journey"] .task-line {
      stroke: ${canvasSubtleLine} !important;
    }
    svg[aria-roledescription="journey"] line[stroke="#666"] {
      stroke: ${canvasLine} !important;
    }
    svg[aria-roledescription="journey"] defs marker path {
      fill: ${canvasLine} !important;
      stroke: ${canvasLine} !important;
    }
    svg[aria-roledescription="journey"] text.legend {
      fill: ${canvasFg} !important;
    }
    svg[aria-roledescription="journey"] > text {
      fill: ${canvasTitleFg} !important;
    }
  `;

  if (isDark) {
    // 脑图 (mindmap) 分支连线在暗色画布下使用高亮彩线，避免与深色节点底色 cScale 一同变暗
    css += `
      svg[aria-roledescription="mindmap"] path.section-edge-0 { stroke: #94A3B8 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-1 { stroke: #60A5FA !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-2 { stroke: #C084FC !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-3 { stroke: #2DD4BF !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-4 { stroke: #FB923C !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-5 { stroke: #F472B6 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-6 { stroke: #A78BFA !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-7 { stroke: #FBBF24 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-8 { stroke: #4ADE80 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-9 { stroke: #818CF8 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-10 { stroke: #38BDF8 !important; }
      svg[aria-roledescription="mindmap"] path.section-edge-11 { stroke: #22D3EE !important; }
    `;
  }

  // 2. 跨深浅色主题画布对比度补偿层：
  if (isDark && theme && theme !== 'auto' && !isThemeBuiltForDark) {
    // 暗黑毛玻璃底 + 浅色系内置主题：保留节点方框内部浅底深字，将暴露在暗色毛玻璃画布上的连线、箭头、连线标签提亮
    css += `
      svg .edgePaths path,
      svg .edges path,
      svg .flowchart-link,
      svg path.transition,
      svg path.relation,
      svg path.relationshipLine,
      svg path.er.relationshipLine,
      svg .messageLine0,
      svg .messageLine1,
      svg .ishikawa-line {
        stroke: #CBD5E1 !important;
      }
      svg defs marker path,
      svg defs marker circle,
      svg defs marker line,
      svg defs marker polygon {
        stroke: #CBD5E1 !important;
      }
      svg defs marker[id*="point"] path,
      svg defs marker[id*="point"] polygon,
      svg defs marker[id*="barb"] path,
      svg defs marker.composition path,
      svg defs marker.dependency path,
      svg defs marker#arrowhead path,
      svg defs marker#filled-head path {
        fill: #CBD5E1 !important;
      }
      svg .loopLine,
      svg .lineWrapper line {
        stroke: #94A3B8 !important;
      }
      svg circle.state-start,
      svg [data-look="neo"].node circle.state-start {
        fill: #E2E8F0 !important;
        stroke: #CBD5E1 !important;
      }
      svg .edgeTerminals text,
      svg .edgeTerminals span,
      svg .edgeTerminals div,
      svg .messageText,
      svg .loopText,
      svg .loopText > tspan,
      svg g.actor-man text,
      svg g.actor-man tspan,
      svg .grid .tick text,
      svg .sectionTitle,
      svg .sectionTitle > tspan,
      svg .titleText,
      svg .flowchartTitleText,
      svg .classTitleText,
      svg .statediagramTitleText,
      svg .erDiagramTitleText,
      svg .requirementDiagramTitleText,
      svg .gitTitleText,
      svg .pieTitleText,
      svg .pieOuterCircle + text,
      svg .legend text,
      svg .taskTextOutsideLeft,
      svg .taskTextOutsideRight,
      svg[aria-roledescription="timeline"] > g > text,
      svg[aria-roledescription="timeline"] > text,
      svg .ishikawa-head-label,
      svg .ishikawa-label,
      svg .ishikawa-label tspan,
      svg .venn-title,
      svg[aria-roledescription="venn"] .label,
      svg[aria-roledescription="venn"] .label tspan,
      svg .treemapSectionLabel,
      svg .treemapSectionValue,
      svg .treemapLabel,
      svg .treemapValue {
        fill: #F1F5F9 !important;
        color: #F1F5F9 !important;
      }
      svg g.actor-man line,
      svg g.actor-man circle {
        stroke: #E2E8F0 !important;
      }
      svg .edgeLabel,
      svg .edgeLabel span,
      svg .edgeLabel div,
      svg .edgeLabel p,
      svg .edgeLabel text,
      svg .edgeLabel tspan {
        color: #F1F5F9 !important;
        fill: #F1F5F9 !important;
        background-color: transparent !important;
      }
      svg .edgeLabel .labelBkg,
      svg .edgeLabel rect {
        background-color: rgba(30, 34, 46, 0.88) !important;
        fill: rgba(30, 34, 46, 0.88) !important;
        opacity: 0.92 !important;
        rx: 4px;
        ry: 4px;
      }
    `;
  } else if (!isDark && isThemeBuiltForDark) {
    // 亮色毛玻璃底 + 深色系内置主题：将暴露在浅色毛玻璃画布上的连线、箭头、连线标签加深
    css += `
      svg .edgePaths path,
      svg .edges path,
      svg .flowchart-link,
      svg path.transition,
      svg path.relation,
      svg path.relationshipLine,
      svg path.er.relationshipLine,
      svg .messageLine0,
      svg .messageLine1,
      svg .ishikawa-line {
        stroke: #334155 !important;
      }
      svg defs marker path,
      svg defs marker circle,
      svg defs marker line,
      svg defs marker polygon {
        stroke: #334155 !important;
      }
      svg defs marker[id*="point"] path,
      svg defs marker[id*="point"] polygon,
      svg defs marker[id*="barb"] path,
      svg defs marker.composition path,
      svg defs marker.dependency path,
      svg defs marker#arrowhead path,
      svg defs marker#filled-head path {
        fill: #334155 !important;
      }
      svg .loopLine,
      svg .lineWrapper line {
        stroke: #64748B !important;
      }
      svg .edgeTerminals text,
      svg .edgeTerminals span,
      svg .edgeTerminals div,
      svg .messageText,
      svg .loopText,
      svg .loopText > tspan,
      svg g.actor-man text,
      svg g.actor-man tspan,
      svg .grid .tick text,
      svg .sectionTitle,
      svg .sectionTitle > tspan,
      svg .titleText,
      svg .flowchartTitleText,
      svg .classTitleText,
      svg .statediagramTitleText,
      svg .erDiagramTitleText,
      svg .requirementDiagramTitleText,
      svg .gitTitleText,
      svg .pieTitleText,
      svg .legend text,
      svg .taskTextOutsideLeft,
      svg .taskTextOutsideRight,
      svg[aria-roledescription="timeline"] > g > text,
      svg[aria-roledescription="timeline"] > text,
      svg .ishikawa-head-label,
      svg .ishikawa-label,
      svg .ishikawa-label tspan,
      svg .venn-title,
      svg[aria-roledescription="venn"] .label,
      svg[aria-roledescription="venn"] .label tspan {
        fill: #1E293B !important;
        color: #1E293B !important;
      }
      svg .edgeLabel,
      svg .edgeLabel span,
      svg .edgeLabel div,
      svg .edgeLabel p,
      svg .edgeLabel text,
      svg .edgeLabel tspan {
        color: #1E293B !important;
        fill: #1E293B !important;
        background-color: transparent !important;
      }
      svg .edgeLabel .labelBkg,
      svg .edgeLabel rect {
        background-color: rgba(255, 255, 255, 0.88) !important;
        fill: rgba(255, 255, 255, 0.88) !important;
        opacity: 0.92 !important;
      }
    `;
  }

  styleEl.textContent = css;
}

function initMermaid(isDark, look, theme) {
  if (!window.mermaid) return;
  const selectedLook = (look === 'handDrawn' || look === 'neo') ? look : 'classic';
  const fontFamily = (selectedLook === 'handDrawn')
    ? '"Chalkboard SE", "Bradley Hand", "Comic Sans MS", "PingFang SC", sans-serif'
    : '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

  updateCanvasContrastCSS(isDark, theme);

  // 修正 Mermaid dark/neo-dark/redux-dark 内部将 scaleLabelColor 设为 black、gitBranchLabel0 设为深灰、
  // attributeBackgroundColorOdd/Even 设为纯白、taskTextDarkColor 设为浅灰、以及 cScale 设为纯黑 (#0b0000 / hsl(..., 0%)) 的缺陷
  const darkSectionVars = {
    scaleLabelColor: '#F8FAFC',
    cScaleLabel0: '#F8FAFC',
    cScaleLabel1: '#F8FAFC',
    cScaleLabel2: '#F8FAFC',
    cScaleLabel3: '#F8FAFC',
    cScaleLabel4: '#F8FAFC',
    cScaleLabel5: '#F8FAFC',
    cScaleLabel6: '#F8FAFC',
    cScaleLabel7: '#F8FAFC',
    cScaleLabel8: '#F8FAFC',
    cScaleLabel9: '#F8FAFC',
    cScaleLabel10: '#F8FAFC',
    cScaleLabel11: '#F8FAFC',
    branchLabelColor: '#F8FAFC',
    gitBranchLabel0: '#F8FAFC',
    gitBranchLabel1: '#F8FAFC',
    gitBranchLabel2: '#F8FAFC',
    gitBranchLabel3: '#F8FAFC',
    gitBranchLabel4: '#F8FAFC',
    gitBranchLabel5: '#F8FAFC',
    gitBranchLabel6: '#F8FAFC',
    gitBranchLabel7: '#F8FAFC',
    git0: '#334155',
    cScale0: '#334155',
    cScale1: '#1E3A5F',
    cScale2: '#4C1D4B',
    cScale3: '#1F4E5B',
    cScale4: '#5C3418',
    cScale5: '#5B1E2D',
    cScale6: '#3B235A',
    cScale7: '#5A4314',
    cScale8: '#1B4D2E',
    cScale9: '#2A344B',
    cScale10: '#173B6C',
    cScale11: '#164E63',
    fillType0: '#1E3A5F',
    fillType1: '#3B235A',
    fillType2: '#1F4E5B',
    fillType3: '#5C3418',
    fillType4: '#4C1D4B',
    fillType5: '#1B4D2E',
    fillType6: '#2A344B',
    fillType7: '#5B1E2D',
    attributeBackgroundColorOdd: '#1E293B',
    attributeBackgroundColorEven: '#0F172A',
    taskTextDarkColor: '#1E293B',
    taskTextColor: '#F8FAFC',
    actorTextColor: '#F1F5F9',
    pieTitleTextColor: '#F8FAFC',
    pieLegendTextColor: '#E2E8F0',
    xyChart: {
      backgroundColor: 'transparent',
      titleColor: '#F8FAFC',
      dataLabelColor: '#F1F5F9',
      legendTextColor: '#E2E8F0',
      xAxisTitleColor: '#F1F5F9',
      xAxisLabelColor: '#CBD5E1',
      xAxisTickColor: '#94A3B8',
      xAxisLineColor: '#94A3B8',
      yAxisTitleColor: '#F1F5F9',
      yAxisLabelColor: '#CBD5E1',
      yAxisTickColor: '#94A3B8',
      yAxisLineColor: '#94A3B8',
      plotColorPalette: '#38BDF8,#34D399,#F472B6,#FBBF24,#A78BFA,#FB923C,#60A5FA,#4ADE80'
    }
  };

  const lightSectionVars = {
    scaleLabelColor: '#0F172A',
    cScaleLabel0: '#0F172A',
    cScaleLabel1: '#0F172A',
    cScaleLabel2: '#0F172A',
    cScaleLabel3: '#0F172A',
    cScaleLabel4: '#0F172A',
    cScaleLabel5: '#0F172A',
    cScaleLabel6: '#0F172A',
    cScaleLabel7: '#0F172A',
    cScaleLabel8: '#0F172A',
    cScaleLabel9: '#0F172A',
    cScaleLabel10: '#0F172A',
    cScaleLabel11: '#0F172A',
    branchLabelColor: '#0F172A',
    gitBranchLabel0: '#0F172A',
    gitBranchLabel1: '#0F172A',
    gitBranchLabel2: '#0F172A',
    gitBranchLabel3: '#0F172A',
    gitBranchLabel4: '#0F172A',
    gitBranchLabel5: '#0F172A',
    gitBranchLabel6: '#0F172A',
    gitBranchLabel7: '#0F172A',
    git0: '#CBD5E1',
    cScale0: '#94A3B8',
    cScale1: '#93C5FD',
    cScale2: '#C4B5FD',
    cScale3: '#86EFAC',
    cScale4: '#FCD34D',
    cScale5: '#F9A8D4',
    cScale6: '#A5B4FC',
    cScale7: '#5EEAD4',
    cScale8: '#FDBA74',
    cScale9: '#F0ABFC',
    cScale10: '#7DD3FC',
    cScale11: '#BEF264',
    xyChart: {
      backgroundColor: 'transparent',
      titleColor: '#0F172A',
      dataLabelColor: '#1E293B',
      legendTextColor: '#334155',
      xAxisTitleColor: '#1E293B',
      xAxisLabelColor: '#334155',
      xAxisTickColor: '#64748B',
      xAxisLineColor: '#64748B',
      yAxisTitleColor: '#1E293B',
      yAxisLabelColor: '#334155',
      yAxisTickColor: '#64748B',
      yAxisLineColor: '#64748B',
      plotColorPalette: '#2563EB,#059669,#DB2777,#D97706,#7C3AED,#EA580C,#0284C7,#16A34A'
    }
  };

  // 跨图表子系统统一配置（C4 / Packet / TreeView / Treemap）
  const sharedDiagramConfigs = {
    c4: {
      useMaxWidth: true,
      person_bg_color: '#08427B',
      person_border_color: '#3C7FC0',
      external_person_bg_color: '#475569',
      external_person_border_color: '#64748B',
      system_bg_color: '#1168BD',
      system_border_color: '#3C7FC0',
      system_db_bg_color: '#1168BD',
      system_db_border_color: '#3C7FC0',
      system_queue_bg_color: '#1168BD',
      system_queue_border_color: '#3C7FC0',
      external_system_bg_color: '#475569',
      external_system_border_color: '#64748B',
      external_system_db_bg_color: '#475569',
      external_system_db_border_color: '#64748B',
      external_system_queue_bg_color: '#475569',
      external_system_queue_border_color: '#64748B',
      container_bg_color: '#2563EB',
      container_border_color: '#60A5FA',
      container_db_bg_color: '#2563EB',
      container_db_border_color: '#60A5FA',
      container_queue_bg_color: '#2563EB',
      container_queue_border_color: '#60A5FA',
      external_container_bg_color: '#475569',
      external_container_border_color: '#64748B',
      external_container_db_bg_color: '#475569',
      external_container_db_border_color: '#64748B',
      external_container_queue_bg_color: '#475569',
      external_container_queue_border_color: '#64748B',
      component_bg_color: '#1D4ED8',
      component_border_color: '#60A5FA',
      component_db_bg_color: '#1D4ED8',
      component_db_border_color: '#60A5FA',
      component_queue_bg_color: '#1D4ED8',
      component_queue_border_color: '#60A5FA',
      external_component_bg_color: '#475569',
      external_component_border_color: '#64748B',
      external_component_db_bg_color: '#475569',
      external_component_db_border_color: '#64748B',
      external_component_queue_bg_color: '#475569',
      external_component_queue_border_color: '#64748B'
    }
  };

  if (!theme || theme === 'auto') {
    // 自动毛玻璃模式：跟随深浅色半透明卡片
    mermaid.initialize(Object.assign({
      startOnLoad: false,
      securityLevel: 'loose',
      look: selectedLook,
      theme: isDark ? 'dark' : 'neutral',
      fontFamily: fontFamily,
      themeVariables: isDark ? Object.assign({
        darkMode: true,
        mainBkg: 'rgba(255, 255, 255, 0.08)',
        nodeBorder: 'rgba(255, 255, 255, 0.25)',
        clusterBkg: 'rgba(255, 255, 255, 0.04)',
        clusterBorder: 'rgba(255, 255, 255, 0.15)',
        titleColor: '#F3F4F6',
        edgeLabelBackground: 'rgba(30, 30, 40, 0.85)',
        textColor: '#E5E7EB',
        lineColor: '#CBD5E1',
        arrowheadColor: '#CBD5E1',
        relationColor: '#CBD5E1',
        transitionColor: '#CBD5E1',
        signalColor: '#E2E8F0',
        actorLineColor: 'rgba(255, 255, 255, 0.45)'
      }, darkSectionVars) : Object.assign({
        darkMode: false,
        mainBkg: 'rgba(0, 0, 0, 0.04)',
        nodeBorder: 'rgba(0, 0, 0, 0.2)',
        clusterBkg: 'rgba(0, 0, 0, 0.02)',
        clusterBorder: 'rgba(0, 0, 0, 0.1)',
        titleColor: '#1F2937',
        edgeLabelBackground: 'rgba(255, 255, 255, 0.85)',
        textColor: '#1F2937',
        lineColor: '#475569',
        arrowheadColor: '#475569',
        relationColor: '#475569',
        transitionColor: '#475569',
        signalColor: '#334155',
        actorLineColor: 'rgba(0, 0, 0, 0.35)'
      }, lightSectionVars)
    }, sharedDiagramConfigs));
  } else {
    // Mermaid 官方原生内置主题：
    // 注意：严禁传入 background: 'transparent'，否则 Mermaid 内部 invert('transparent') 会算出
    // rgba(255, 255, 255, 0) 全透明色，导致 lineColor / relationColor / transitionColor 连线隐形！
    const isThemeBuiltForDark = (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark' || theme === 'redux-dark-color');
    let canvasVars = {};
    if (theme === 'dark' || theme === 'neo-dark' || theme === 'redux-dark') {
      Object.assign(canvasVars, darkSectionVars);
    } else if (theme === 'redux-dark-color') {
      canvasVars.attributeBackgroundColorOdd = '#1E293B';
      canvasVars.attributeBackgroundColorEven = '#0F172A';
      canvasVars.taskTextDarkColor = '#1E293B';
      canvasVars.taskTextColor = '#F8FAFC';
      canvasVars.actorTextColor = '#F1F5F9';
      canvasVars.pieTitleTextColor = '#F8FAFC';
      canvasVars.pieLegendTextColor = '#E2E8F0';
      canvasVars.xyChart = darkSectionVars.xyChart;
    } else if (theme === 'default') {
      canvasVars.cScaleLabel0 = '#1E293B';
      canvasVars.cScaleLabel3 = '#1E293B';
    }

    if (isDark && !isThemeBuiltForDark) {
      Object.assign(canvasVars, {
        lineColor: '#CBD5E1',
        arrowheadColor: '#CBD5E1',
        defaultLinkColor: '#CBD5E1',
        transitionColor: '#CBD5E1',
        relationColor: '#CBD5E1',
        archEdgeColor: '#CBD5E1',
        archEdgeArrowColor: '#CBD5E1',
        actorLineColor: '#94A3B8',
        signalColor: '#E2E8F0',
        signalTextColor: '#F1F5F9',
        loopTextColor: '#F1F5F9',
        titleColor: '#F8FAFC',
        edgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
        relationLabelBackground: 'rgba(30, 34, 46, 0.88)',
        erEdgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
        requirementEdgeLabelBackground: 'rgba(30, 34, 46, 0.88)',
        relationLabelColor: '#F1F5F9',
        transitionLabelColor: '#F1F5F9',
        sequenceNumberColor: '#0F172A',
        specialStateColor: '#E2E8F0',
        innerEndBackground: '#E2E8F0',
        pieTitleTextColor: '#F8FAFC',
        pieLegendTextColor: '#E2E8F0',
        quadrantTitleFill: '#F8FAFC',
        quadrantXAxisTextFill: '#E2E8F0',
        quadrantYAxisTextFill: '#E2E8F0',
        taskTextOutsideColor: '#E2E8F0',
        xyChart: darkSectionVars.xyChart
      });
    } else if (!isDark && isThemeBuiltForDark) {
      Object.assign(canvasVars, {
        lineColor: '#334155',
        arrowheadColor: '#334155',
        defaultLinkColor: '#334155',
        transitionColor: '#334155',
        relationColor: '#334155',
        archEdgeColor: '#334155',
        archEdgeArrowColor: '#334155',
        actorLineColor: '#64748B',
        signalColor: '#1E293B',
        signalTextColor: '#1E293B',
        loopTextColor: '#1E293B',
        titleColor: '#0F172A',
        edgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
        relationLabelBackground: 'rgba(255, 255, 255, 0.88)',
        erEdgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
        requirementEdgeLabelBackground: 'rgba(255, 255, 255, 0.88)',
        relationLabelColor: '#1E293B',
        transitionLabelColor: '#1E293B',
        sequenceNumberColor: '#FFFFFF',
        xyChart: lightSectionVars.xyChart
      });
    }

    mermaid.initialize(Object.assign({
      startOnLoad: false,
      securityLevel: 'loose',
      look: selectedLook,
      theme: theme,
      fontFamily: fontFamily,
      themeVariables: canvasVars
    }, sharedDiagramConfigs));
  }
}

window.renderDiagram = function(code, isDark, look, theme) {
  if (renderTimer) clearTimeout(renderTimer);
  renderTimer = setTimeout(() => {
    doRenderDiagram(code, isDark, look || 'classic', theme || 'auto');
  }, 40);
};

function normalizeDiagram(container, isDark, look, theme) {
  const svgEl = container.querySelector('svg');
  if (!svgEl) return;

  // 0. 手绘风格 (handDrawn) 节点衬底可读性增强：
  //    Rough.js 手绘模式默认以稀疏斜线 (fill="none" + stroke) 绘制节点填充，无实心底色；
  //    当暗黑毛玻璃画布搭配浅色系主题（节点内为深色字）或 C4 外部系统块（浅灰斜线 + 白字）时，
  //    斜线缝隙透出底色会导致文字难以辨认。此处为手绘填充路径注入同色系半透明衬底，既保留手绘笔触又确保文字锐利清晰。
  if (look === 'handDrawn') {
    const roughPaths = svgEl.querySelectorAll('g.node path[fill="none"][stroke], g.c4-shape path[fill="none"][stroke], g.cluster path[fill="none"][stroke]');
    roughPaths.forEach(p => {
      const sw = parseFloat(p.getAttribute('stroke-width') || '1');
      const d = p.getAttribute('d') || '';
      // Rough.js hachure 阴影路径特征：stroke-width >= 2.5 或包含多段 M...L 排线
      const mCount = (d.match(/M/g) || []).length;
      if (sw >= 2.5 || mCount >= 4) {
        const st = p.getAttribute('stroke') || '';
        // 若后续兄弟节点是边框闭合路径，则在边框路径上注入半透明实心衬底
        const nextPath = p.nextElementSibling;
        if (nextPath && nextPath.tagName.toLowerCase() === 'path' && (!nextPath.getAttribute('fill') || nextPath.getAttribute('fill') === 'none')) {
          nextPath.setAttribute('fill', st);
          nextPath.setAttribute('fill-opacity', '0.82');
        }
      }
    });
  }

  // 1. 根治 journey 与 c4 图表硬编码 height / 偏移 viewBox 导致的巨幅留白与标题偏置：
  //    - journey 渲染器强行写入 height="565"，且将标题高度 70px 误加至底部 viewBox；
  //    - c4 渲染器将 viewBox 起点设为 y=-70（而图形从 y=110 起绘），且将标题置于 v/2 - 200 偏左位置。
  //    此处对 c4 标题居中归位，并按实际图形几何边界 (getBBox) 收紧 journey 与 c4 的 viewBox。
  const roleDesc = svgEl.getAttribute('aria-roledescription');
  if (roleDesc === 'c4') {
    try {
      const c4Title = svgEl.querySelector(':scope > text');
      if (c4Title) {
        c4Title.style.display = 'none';
        const shapesBox = svgEl.getBBox();
        c4Title.style.display = '';
        if (shapesBox && shapesBox.width > 0) {
          c4Title.setAttribute('x', String(shapesBox.x + shapesBox.width / 2));
          c4Title.setAttribute('y', String(shapesBox.y - 24));
          c4Title.setAttribute('text-anchor', 'middle');
        }
      }
    } catch (_) {}
  }
  if (roleDesc === 'journey' || roleDesc === 'c4') {
    try {
      const bbox = svgEl.getBBox();
      if (bbox && bbox.width > 0 && bbox.height > 0) {
        const padX = 16;
        const padY = 12;
        svgEl.setAttribute(
          'viewBox',
          `${bbox.x - padX} ${bbox.y - padY} ${bbox.width + padX * 2} ${bbox.height + padY * 2}`
        );
      }
    } catch (_) {}
  }
  if (svgEl.getAttribute('viewBox')) {
    svgEl.removeAttribute('height');
  }

  // 2. 根治时序图泳道生命线穿刺顶部参与者方框：
  //    Mermaid 原生绘制生命线从顶部方框内的 y=5 起笔，依赖不透明背景遮挡；
  //    在 macOS 毛玻璃半透明体系下，生命线会透过半透明方框暴露。
  //    此处从几何底层将生命线起点截断在方框底边（bottomY），彻底根治穿刺。
  const topActors = svgEl.querySelectorAll('rect.actor-top, g.actor-top');
  if (topActors.length > 0) {
    const lines = svgEl.querySelectorAll('line');
    topActors.forEach(actor => {
      let rx, rw, ry, rh;
      if (actor.tagName.toLowerCase() === 'rect') {
        rx = parseFloat(actor.getAttribute('x'));
        rw = parseFloat(actor.getAttribute('width'));
        ry = parseFloat(actor.getAttribute('y'));
        rh = parseFloat(actor.getAttribute('height'));
      } else if (typeof actor.getBBox === 'function') {
        try {
          const bbox = actor.getBBox();
          rx = bbox.x; rw = bbox.width; ry = bbox.y; rh = bbox.height;
        } catch (_) { return; }
      }
      if (isNaN(rx) || isNaN(rw) || isNaN(ry) || isNaN(rh)) return;
      const centerX = rx + rw / 2;
      const bottomY = ry + rh;

      lines.forEach(line => {
        const lx1 = parseFloat(line.getAttribute('x1'));
        const lx2 = parseFloat(line.getAttribute('x2'));
        const ly1 = parseFloat(line.getAttribute('y1'));
        if (isNaN(lx1) || isNaN(lx2) || isNaN(ly1)) return;
        // 垂直生命线：x 坐标在中轴线附近 (±2px 容差)，且起点深入方框内部 (ly1 < bottomY)
        if (Math.abs(lx1 - lx2) < 0.5 && Math.abs(lx1 - centerX) < 2 && ly1 < bottomY) {
          line.setAttribute('y1', bottomY);
        }
      });
    });
  }

  // 3. 根治 ER 图（erDiagram）关系连接线终端符号穿刺半透明实体框：
  //    Mermaid 原生将 ER 关系线绘制在实体框图层下方，且将鱼尾分叉（ONE_OR_MORE / ZERO_OR_MORE）的 refX 设在
  //    中心点并向实体框内部延伸 18px，依赖不透明实体框背景遮挡。在毛玻璃半透明主题下会穿透实体框遮挡表名。
  //    此处配合开放式鱼尾分叉路径，通过 SVG userSpaceOnUse 遮罩将所有实体框内部区域从关系线图层中精准镂空，
  //    确保任意角度入射的鱼尾三叉均严丝合缝止步于实体框外边缘。
  const relLines = svgEl.querySelectorAll('path.er.relationshipLine');
  const entityBoxes = svgEl.querySelectorAll('g[id^="entity-"] > rect.er.entityBox, g[id^="entity-"] > path');
  if (relLines.length > 0 && entityBoxes.length > 0) {
    const ns = 'http://www.w3.org/2000/svg';
    let defs = svgEl.querySelector('defs');
    if (!defs) {
      defs = document.createElementNS(ns, 'defs');
      svgEl.insertBefore(defs, svgEl.firstChild);
    }
    const maskId = (svgEl.id || 'mermaid-er') + '-entity-mask';
    const mask = document.createElementNS(ns, 'mask');
    mask.setAttribute('id', maskId);
    mask.setAttribute('maskUnits', 'userSpaceOnUse');
    mask.setAttribute('maskContentUnits', 'userSpaceOnUse');
    mask.setAttribute('x', '-10000');
    mask.setAttribute('y', '-10000');
    mask.setAttribute('width', '20000');
    mask.setAttribute('height', '20000');

    const bg = document.createElementNS(ns, 'rect');
    bg.setAttribute('x', '-10000');
    bg.setAttribute('y', '-10000');
    bg.setAttribute('width', '20000');
    bg.setAttribute('height', '20000');
    bg.setAttribute('fill', 'white');
    mask.appendChild(bg);

    entityBoxes.forEach(box => {
      const g = box.parentElement;
      const transform = (g && g.getAttribute('transform')) || '';
      let tx = 0, ty = 0;
      const tStart = transform.indexOf('translate(');
      if (tStart !== -1) {
        const tEnd = transform.indexOf(')', tStart);
        if (tEnd !== -1) {
          const parts = transform.slice(tStart + 10, tEnd).trim().split(/[ ,]+/);
          tx = parseFloat(parts[0]) || 0;
          ty = parseFloat(parts[1]) || 0;
        }
      }
      let bx = parseFloat(box.getAttribute('x'));
      let by = parseFloat(box.getAttribute('y'));
      let bw = parseFloat(box.getAttribute('width'));
      let bh = parseFloat(box.getAttribute('height'));
      if (isNaN(bx) || isNaN(bw)) {
        try {
          const bbox = box.getBBox();
          bx = bbox.x; by = bbox.y; bw = bbox.width; bh = bbox.height;
        } catch (_) { return; }
      }
      if (bw > 0 && bh > 0) {
        const cut = document.createElementNS(ns, 'rect');
        cut.setAttribute('x', String(tx + bx));
        cut.setAttribute('y', String(ty + by));
        cut.setAttribute('width', String(bw));
        cut.setAttribute('height', String(bh));
        cut.setAttribute('fill', 'black');
        mask.appendChild(cut);
      }
    });
    defs.appendChild(mask);

    const relGroup = document.createElementNS(ns, 'g');
    relGroup.setAttribute('mask', `url(#${maskId})`);
    const firstLine = relLines[0];
    if (firstLine.parentNode) {
      firstLine.parentNode.insertBefore(relGroup, firstLine);
      relLines.forEach(line => relGroup.appendChild(line));
    }
  }
}

async function doRenderDiagram(code, isDark, look, theme) {
  const container = document.getElementById('container');
  if (!window.mermaid) {
    window.webkit.messageHandlers.mermaidBridge.postMessage({
      type: 'error',
      message: 'mermaid library not available'
    });
    return;
  }

  if (!code || !code.trim()) {
    container.innerHTML = '';
    lastReportedHeight = 0;
    window.webkit.messageHandlers.mermaidBridge.postMessage({
      type: 'rendered',
      height: 0
    });
    return;
  }

  if (document.body.clientWidth < 10) {
    pendingRenderArgs = { code, isDark, look, theme };
    return;
  }

  const renderId = 'mermaid-render-' + (++renderCounter);
  initMermaid(isDark, look, theme);

  try {
    const normalizedCode = normalizeMermaidSource(code);
    const { svg } = await mermaid.render(renderId, normalizedCode);
    container.innerHTML = svg;
    normalizeDiagram(container, isDark, look, theme);

    const svgEl = container.querySelector('svg');
    if (svgEl) {
      resizeObserver.observe(svgEl);
    }

    lastReportedHeight = 0;
    requestAnimationFrame(() => {
      reportContainerHeight();
    });
  } catch (err) {
    container.innerHTML = '';
    const tempErr = document.getElementById('d' + renderId);
    if (tempErr) tempErr.remove();

    window.webkit.messageHandlers.mermaidBridge.postMessage({
      type: 'error',
      message: err.message || 'Render failed'
    });
  }
}
