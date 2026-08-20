#!/usr/bin/env node

"use strict";

const fs = require("fs");
const path = require("path");
const PptxGenJS = require("pptxgenjs");

const [, , inputPath, outputPath, designKbRoot] = process.argv;

if (!inputPath || !outputPath || !designKbRoot) {
  console.error("usage: generator.cjs <input.json> <output.pptx> <design-kb-root>");
  process.exit(2);
}

const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
if (input.template) {
  console.error("template ingestion is handled by the compatible Python engine");
  process.exit(64);
}

const readJson = (name) =>
  JSON.parse(fs.readFileSync(path.join(designKbRoot, name), "utf8"));
const paletteConfig = readJson("palettes.json");
const typographyConfig = readJson("typography.json");

const stripHash = (value) => String(value || "").replace(/^#/, "");
const selectedPalette =
  paletteConfig.palettes.find((item) => item.id === input.theme) ||
  paletteConfig.palettes.find((item) => item.id === "midnight") ||
  paletteConfig.palettes[0];
const colors = Object.fromEntries(
  Object.entries(selectedPalette).map(([key, value]) => [key, stripHash(value)])
);
const scale = typographyConfig.scale || {};
const grid = typographyConfig.grid || {};
const W = Number(grid.slide_w_in || 13.333);
const H = Number(grid.slide_h_in || 7.5);
const M = Number(grid.margin_in || 0.9);
const BODY_FONT = process.platform === "win32" ? "Microsoft YaHei" : "PingFang SC";
const TITLE_FONT = process.platform === "win32" ? "Microsoft YaHei UI" : "PingFang SC";
const MONO_FONT = process.platform === "win32" ? "Cascadia Mono" : "Menlo";

const pptx = new PptxGenJS();
pptx.layout = "LAYOUT_WIDE";
pptx.author = "LingShu DesignKB";
pptx.company = "LingShu";
pptx.subject = input.title || "Presentation";
pptx.title = input.title || "Presentation";
pptx.lang = "zh-CN";
pptx.theme = {
  headFontFace: TITLE_FONT,
  bodyFontFace: BODY_FONT,
  lang: "zh-CN",
};
pptx.defineSlideMaster({
  title: "LINGSHU",
  background: { color: colors.bg },
  objects: [
    {
      line: {
        x: M,
        y: H - 0.5,
        w: W - M * 2,
        h: 0,
        line: { color: colors.muted, transparency: 72, width: 0.6 },
      },
    },
    {
      text: {
        text: input.title || "LingShu",
        options: {
          x: M,
          y: H - 0.38,
          w: 7.5,
          h: 0.18,
          fontFace: BODY_FONT,
          fontSize: 7,
          color: colors.muted,
          transparency: 18,
          margin: 0,
          charSpacing: 0.5,
        },
      },
    },
  ],
  slideNumber: {
    x: W - M - 0.45,
    y: H - 0.41,
    w: 0.45,
    h: 0.2,
    color: colors.muted,
    fontFace: MONO_FONT,
    fontSize: 8,
    align: "right",
    margin: 0,
  },
});

const shape = pptx.ShapeType;
const chartType = pptx.ChartType;
const slides = Array.isArray(input.slides) ? input.slides : [];

function text(value) {
  if (value === null || value === undefined) return "";
  return String(value);
}

function cleanList(value) {
  return Array.isArray(value) ? value.map(text).filter(Boolean) : [];
}

function addText(slide, value, options = {}) {
  slide.addText(text(value), {
    fontFace: BODY_FONT,
    color: colors.ink,
    margin: 0,
    breakLine: false,
    fit: "shrink",
    valign: "mid",
    ...options,
  });
}

function addTitle(slide, title, subtitle) {
  addText(slide, title, {
    x: M,
    y: 0.55,
    w: W - M * 2,
    h: 0.46,
    fontFace: TITLE_FONT,
    fontSize: Number(scale.title || 32),
    bold: true,
    valign: "top",
  });
  slide.addShape(shape.line, {
    x: M,
    y: 1.12,
    w: 0.72,
    h: 0,
    line: { color: colors.accent, width: 4, beginArrowType: "none", endArrowType: "none" },
  });
  if (subtitle) {
    addText(slide, subtitle, {
      x: M + 0.92,
      y: 1.01,
      w: W - M * 2 - 0.92,
      h: 0.28,
      fontSize: Number(scale.subtitle || 18),
      color: colors.muted,
    });
  }
}

function addKicker(slide, value, x = M, y = 0.45) {
  if (!value) return;
  addText(slide, text(value).toUpperCase(), {
    x,
    y,
    w: 5.2,
    h: 0.22,
    fontFace: MONO_FONT,
    fontSize: 9,
    bold: true,
    color: colors.accent,
    charSpacing: 1.6,
  });
}

function addBulletList(slide, bullets, box, options = {}) {
  const items = cleanList(bullets);
  if (!items.length) return;
  const gap = Number(options.gap || 0.16);
  const itemHeight = Math.max(0.45, Math.min(0.82, (box.h - gap * (items.length - 1)) / items.length));
  items.forEach((item, index) => {
    const y = box.y + index * (itemHeight + gap);
    slide.addShape(shape.ellipse, {
      x: box.x,
      y: y + itemHeight / 2 - 0.055,
      w: 0.11,
      h: 0.11,
      fill: { color: index === 0 ? colors.accent : colors.accent2 },
      line: { color: index === 0 ? colors.accent : colors.accent2, transparency: 100 },
    });
    addText(slide, item, {
      x: box.x + 0.28,
      y,
      w: box.w - 0.28,
      h: itemHeight,
      fontSize: Number(options.fontSize || scale.bullet || 18),
      color: options.color || colors.ink,
      bold: index === 0 && Boolean(options.emphasizeFirst),
      valign: "mid",
    });
  });
}

function addPanel(slide, box, options = {}) {
  slide.addShape(shape.roundRect, {
    ...box,
    rectRadius: 0.06,
    fill: { color: options.fill || colors.surface, transparency: options.transparency || 0 },
    line: {
      color: options.line || colors.muted,
      transparency: options.lineTransparency === undefined ? 72 : options.lineTransparency,
      width: options.lineWidth || 0.8,
    },
    shadow: options.shadow === false ? undefined : { type: "outer", color: "000000", opacity: 0.12, blur: 1, angle: 45, distance: 1 },
  });
}

function imageMimeType(imagePath) {
  switch (path.extname(imagePath).toLowerCase()) {
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".svg":
      return "image/svg+xml";
    case ".webp":
      return "image/webp";
    case ".png":
    default:
      return "image/png";
  }
}

function addImage(slide, imagePath, box, overlay = false) {
  if (!imagePath || !fs.existsSync(imagePath)) return false;
  const data = `data:${imageMimeType(imagePath)};base64,${fs.readFileSync(imagePath).toString("base64")}`;
  slide.addImage({ data, ...box });
  if (overlay) {
    slide.addShape(shape.rect, {
      ...box,
      fill: { color: colors.bg, transparency: 35 },
      line: { color: colors.bg, transparency: 100 },
    });
  }
  return true;
}

function addMetric(slide, metric, box, accent = colors.accent) {
  addPanel(slide, box, { line: accent, lineTransparency: 45 });
  addText(slide, metric.value || metric.number || "-", {
    x: box.x + 0.25,
    y: box.y + 0.28,
    w: box.w - 0.5,
    h: box.h * 0.48,
    fontFace: TITLE_FONT,
    fontSize: Math.min(44, Number(scale.bignum || 120) * 0.36),
    bold: true,
    color: accent,
    valign: "bottom",
  });
  addText(slide, metric.label || metric.desc || "", {
    x: box.x + 0.25,
    y: box.y + box.h * 0.64,
    w: box.w - 0.5,
    h: box.h * 0.22,
    fontSize: 12,
    color: colors.muted,
    valign: "top",
  });
}

function addCover(slide, spec) {
  slide.background = { color: colors.bg };
  const hasImage = addImage(slide, spec.image, { x: 7.7, y: 0, w: W - 7.7, h: H }, true);
  slide.addShape(shape.rect, {
    x: 0,
    y: 0,
    w: hasImage ? 8.65 : W,
    h: H,
    fill: { color: colors.bg, transparency: hasImage ? 3 : 0 },
    line: { color: colors.bg, transparency: 100 },
  });
  slide.addShape(shape.arc, {
    x: W - 3.5,
    y: -1.25,
    w: 5.2,
    h: 5.2,
    adjustPoint: 0.22,
    rotate: 18,
    fill: { color: colors.accent2, transparency: 88 },
    line: { color: colors.accent2, transparency: 44, width: 1.2 },
  });
  addKicker(slide, spec.kicker || spec.eyebrow || "LINGSHU / DESIGNKB", M, 0.85);
  addText(slide, spec.title || input.title, {
    x: M,
    y: 1.65,
    w: hasImage ? 6.9 : 9.7,
    h: 1.65,
    fontFace: TITLE_FONT,
    fontSize: Number(scale.cover_title || 54),
    bold: true,
    valign: "mid",
    breakLine: false,
  });
  addText(slide, spec.subtitle || "", {
    x: M,
    y: 3.55,
    w: hasImage ? 6.45 : 8.6,
    h: 0.72,
    fontSize: Number(scale.cover_subtitle || 22),
    color: colors.muted,
    valign: "top",
  });
  slide.addShape(shape.line, {
    x: M,
    y: 4.7,
    w: 1.18,
    h: 0,
    line: { color: colors.accent, width: 5 },
  });
  addText(slide, spec.contact || spec.meta || "", {
    x: M,
    y: 5.05,
    w: 6.5,
    h: 0.36,
    fontFace: MONO_FONT,
    fontSize: 10,
    color: colors.muted,
    charSpacing: 0.8,
  });
}

function addAgenda(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const items = cleanList(spec.bullets || spec.items);
  const columns = items.length > 5 ? 2 : 1;
  const perColumn = Math.ceil(items.length / columns);
  const columnW = columns === 2 ? 5.72 : 9.8;
  items.forEach((item, index) => {
    const col = Math.floor(index / perColumn);
    const row = index % perColumn;
    const x = M + col * (columnW + 0.55);
    const y = 1.65 + row * 0.82;
    addText(slide, String(index + 1).padStart(2, "0"), {
      x,
      y,
      w: 0.58,
      h: 0.48,
      fontFace: MONO_FONT,
      fontSize: 13,
      bold: true,
      color: colors.accent,
      valign: "mid",
    });
    slide.addShape(shape.line, {
      x: x + 0.68,
      y: y + 0.24,
      w: 0.34,
      h: 0,
      line: { color: colors.muted, transparency: 55, width: 1 },
    });
    addText(slide, item, {
      x: x + 1.16,
      y,
      w: columnW - 1.16,
      h: 0.48,
      fontSize: 18,
      bold: true,
    });
  });
}

function addSection(slide, spec) {
  slide.background = { color: colors.surface };
  slide.addShape(shape.rect, {
    x: 0,
    y: 0,
    w: 0.22,
    h: H,
    fill: { color: colors.accent },
    line: { color: colors.accent, transparency: 100 },
  });
  addText(slide, text(spec.index || "SECTION").padStart(2, "0"), {
    x: 1.05,
    y: 1.15,
    w: 2,
    h: 0.4,
    fontFace: MONO_FONT,
    fontSize: Number(scale.section_index || 20),
    bold: true,
    color: colors.accent,
    charSpacing: 2,
  });
  addText(slide, spec.title, {
    x: 1.05,
    y: 2.05,
    w: 9.8,
    h: 1.35,
    fontFace: TITLE_FONT,
    fontSize: Number(scale.section_title || 40),
    bold: true,
    valign: "mid",
  });
  addText(slide, spec.subtitle || "", {
    x: 1.05,
    y: 3.72,
    w: 8.4,
    h: 0.62,
    fontSize: 19,
    color: colors.muted,
    valign: "top",
  });
  slide.addShape(shape.arc, {
    x: 9.4,
    y: 0.75,
    w: 4.9,
    h: 4.9,
    rotate: 40,
    fill: { color: colors.accent2, transparency: 90 },
    line: { color: colors.accent2, transparency: 40, width: 1.1 },
  });
}

function addBullets(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const bullets = cleanList(spec.bullets);
  const metrics = Array.isArray(spec.metrics) ? spec.metrics : [];
  if (metrics.length) {
    const metricW = Math.min(3.15, (W - M * 2 - 0.44 * (metrics.length - 1)) / metrics.length);
    metrics.slice(0, 4).forEach((metric, index) =>
      addMetric(slide, metric, { x: M + index * (metricW + 0.44), y: 1.55, w: metricW, h: 1.55 }, index % 2 ? colors.accent2 : colors.accent)
    );
    addBulletList(slide, bullets, { x: M, y: 3.45, w: W - M * 2, h: 2.8 }, { fontSize: 17, emphasizeFirst: true });
  } else {
    addPanel(slide, { x: M, y: 1.55, w: W - M * 2, h: 4.95 }, { lineTransparency: 84 });
    addBulletList(slide, bullets, { x: M + 0.5, y: 1.9, w: W - M * 2 - 1, h: 4.25 }, { fontSize: 18, emphasizeFirst: true });
  }
}

function addBigNumber(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const metrics = Array.isArray(spec.metrics) && spec.metrics.length
    ? spec.metrics
    : [{ value: spec.value || "-", label: spec.label || spec.desc || "" }];
  const count = Math.min(metrics.length, 4);
  const gap = 0.35;
  const boxW = (W - M * 2 - gap * (count - 1)) / count;
  metrics.slice(0, count).forEach((metric, index) =>
    addMetric(slide, metric, { x: M + index * (boxW + gap), y: 1.75, w: boxW, h: 3.75 }, index % 2 ? colors.accent2 : colors.accent)
  );
  if (spec.caption || spec.desc) {
    addText(slide, spec.caption || spec.desc, {
      x: M,
      y: 5.82,
      w: W - M * 2,
      h: 0.42,
      fontSize: 13,
      color: colors.muted,
      align: "center",
    });
  }
}

function addImageSplit(slide, spec, imageOnLeft) {
  addTitle(slide, spec.title, spec.subtitle);
  const imageX = imageOnLeft ? M : 7.0;
  const textX = imageOnLeft ? 6.9 : M;
  const imageW = 5.45;
  addPanel(slide, { x: imageX, y: 1.55, w: imageW, h: 4.8 }, { lineTransparency: 90 });
  if (!addImage(slide, spec.image, { x: imageX, y: 1.55, w: imageW, h: 4.8 })) {
    slide.addShape(shape.arc, {
      x: imageX + 1.15,
      y: 2.0,
      w: 3.2,
      h: 3.2,
      rotate: 30,
      fill: { color: colors.accent2, transparency: 83 },
      line: { color: colors.accent, transparency: 42, width: 1.2 },
    });
  }
  addBulletList(slide, spec.bullets, { x: textX, y: 1.75, w: 5.4, h: 4.4 }, { fontSize: 17, emphasizeFirst: true });
}

function addImageFull(slide, spec) {
  const imageAdded = addImage(slide, spec.image, { x: 0, y: 0, w: W, h: H }, true);
  if (!imageAdded) slide.background = { color: colors.surface };
  slide.addShape(shape.rect, {
    x: 0,
    y: 0,
    w: W,
    h: H,
    fill: { color: colors.bg, transparency: imageAdded ? 38 : 0 },
    line: { color: colors.bg, transparency: 100 },
  });
  addKicker(slide, spec.kicker || "INSIGHT", M, 0.75);
  addText(slide, spec.title, {
    x: M,
    y: 1.45,
    w: 9.8,
    h: 1.25,
    fontFace: TITLE_FONT,
    fontSize: 42,
    bold: true,
  });
  addText(slide, spec.subtitle || spec.caption || "", {
    x: M,
    y: 3.0,
    w: 7.3,
    h: 1.0,
    fontSize: 20,
    color: colors.muted,
    valign: "top",
  });
}

function addTwoColumn(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const left = spec.left || {};
  const right = spec.right || {};
  const boxes = [
    { data: left, x: M, accent: colors.accent },
    { data: right, x: 6.82, accent: colors.accent2 },
  ];
  boxes.forEach(({ data, x, accent }) => {
    addPanel(slide, { x, y: 1.55, w: 5.62, h: 4.9 }, { line: accent, lineTransparency: 55 });
    addText(slide, data.title || data.label || "", {
      x: x + 0.4,
      y: 1.88,
      w: 4.82,
      h: 0.45,
      fontFace: TITLE_FONT,
      fontSize: 20,
      bold: true,
      color: accent,
    });
    addBulletList(slide, data.bullets || [], { x: x + 0.4, y: 2.55, w: 4.78, h: 3.35 }, { fontSize: 15 });
  });
}

function addTimeline(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const items = Array.isArray(spec.items) ? spec.items.slice(0, 6) : [];
  if (!items.length) return;
  const startX = M + 0.35;
  const endX = W - M - 0.35;
  const step = items.length === 1 ? 0 : (endX - startX) / (items.length - 1);
  slide.addShape(shape.line, {
    x: startX,
    y: 3.15,
    w: endX - startX,
    h: 0,
    line: { color: colors.muted, transparency: 45, width: 2 },
  });
  items.forEach((item, index) => {
    const x = startX + index * step;
    const accent = index % 2 ? colors.accent2 : colors.accent;
    slide.addShape(shape.ellipse, {
      x: x - 0.14,
      y: 3.01,
      w: 0.28,
      h: 0.28,
      fill: { color: accent },
      line: { color: colors.bg, width: 2 },
    });
    addText(slide, item.label || item.title || String(index + 1), {
      x: x - 0.78,
      y: index % 2 ? 3.55 : 2.18,
      w: 1.56,
      h: 0.36,
      fontSize: 14,
      bold: true,
      color: accent,
      align: "center",
    });
    addText(slide, item.desc || item.description || "", {
      x: x - 0.9,
      y: index % 2 ? 4.05 : 1.55,
      w: 1.8,
      h: 0.6,
      fontSize: 10.5,
      color: colors.muted,
      align: "center",
      valign: index % 2 ? "top" : "bottom",
    });
  });
}

function addQuote(slide, spec) {
  slide.background = { color: colors.surface };
  addText(slide, "“", {
    x: M,
    y: 0.55,
    w: 1.25,
    h: 1.05,
    fontFace: "Georgia",
    fontSize: 76,
    bold: true,
    color: colors.accent,
  });
  addText(slide, spec.quote || spec.title, {
    x: 1.55,
    y: 1.4,
    w: 10.2,
    h: 2.45,
    fontFace: TITLE_FONT,
    fontSize: Number(scale.quote || 30),
    bold: true,
    align: "center",
    valign: "mid",
  });
  slide.addShape(shape.line, {
    x: 5.65,
    y: 4.5,
    w: 2.0,
    h: 0,
    line: { color: colors.accent2, width: 2.5 },
  });
  addText(slide, spec.attrib || spec.subtitle || "", {
    x: 3.1,
    y: 4.85,
    w: 7.1,
    h: 0.42,
    fontSize: 14,
    color: colors.muted,
    align: "center",
  });
}

function addChart(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const chart = spec.chart || {};
  const categories = cleanList(chart.categories || chart.labels);
  const series = Array.isArray(chart.series) ? chart.series : [];
  const chartData = series.map((item, index) => ({
    name: text(item.name || `Series ${index + 1}`),
    labels: categories,
    values: Array.isArray(item.values) ? item.values.map(Number) : [],
  }));
  const type = chart.type === "line" ? chartType.line : chart.type === "pie" ? chartType.pie : chartType.bar;
  addPanel(slide, { x: M, y: 1.45, w: 8.35, h: 4.95 }, { lineTransparency: 88 });
  if (chartData.length && categories.length) {
    slide.addChart(type, chartData, {
      x: M + 0.25,
      y: 1.72,
      w: 7.85,
      h: 4.35,
      catAxisLabelColor: colors.muted,
      valAxisLabelColor: colors.muted,
      showLegend: chartData.length > 1 || type === chartType.pie,
      legendColor: colors.muted,
      legendPos: "b",
      showTitle: false,
      chartColors: [colors.accent, colors.accent2, "67E8F9", "F59E0B", "F472B6"],
      showValue: type !== chartType.pie,
      showCatName: type === chartType.pie,
      showPercent: type === chartType.pie,
      dataLabelColor: colors.ink,
      dataLabelFontSize: 10,
      showBorder: false,
      showGridLines: type !== chartType.pie,
      gridLine: { color: colors.muted, transparency: 80, width: 0.5 },
      valGridLine: { color: colors.muted, transparency: 80, width: 0.5 },
      showLegendKey: false,
      showSerName: false,
      showLeaderLines: true,
      border: { color: colors.surface, transparency: 100 },
    });
  } else {
    addText(slide, "No chart data", { x: M + 0.5, y: 3.4, w: 7.35, h: 0.4, color: colors.muted, align: "center" });
  }
  const takeaways = cleanList(spec.bullets || spec.insights);
  addText(slide, spec.side_title || "KEY TAKEAWAYS", {
    x: 9.55,
    y: 1.62,
    w: 2.85,
    h: 0.3,
    fontFace: MONO_FONT,
    fontSize: 10,
    bold: true,
    color: colors.accent,
    charSpacing: 1,
  });
  addBulletList(slide, takeaways, { x: 9.55, y: 2.1, w: 2.85, h: 3.95 }, { fontSize: 13.5 });
}

function addCompare(slide, spec) {
  addTitle(slide, spec.title, spec.subtitle);
  const columns = cleanList(spec.columns);
  const rows = Array.isArray(spec.rows) ? spec.rows : [];
  if (columns.length && rows.length) {
    const table = [columns, ...rows.map((row) => (Array.isArray(row) ? row.map(text) : []))];
    slide.addTable(table, {
      x: M,
      y: 1.55,
      w: W - M * 2,
      h: 4.85,
      border: { color: colors.muted, transparency: 70, width: 0.6 },
      fill: colors.surface,
      color: colors.ink,
      fontFace: BODY_FONT,
      fontSize: 12,
      margin: 0.12,
      valign: "mid",
      autoFit: false,
      bold: false,
      rowH: 0.5,
      colW: (W - M * 2) / columns.length,
      alternateRowFill: colors.bg,
    });
    slide.addShape(shape.rect, {
      x: M,
      y: 1.55,
      w: W - M * 2,
      h: 0.5,
      fill: { color: colors.accent, transparency: 20 },
      line: { color: colors.accent, transparency: 100 },
    });
    columns.forEach((column, index) =>
      addText(slide, column, {
        x: M + index * ((W - M * 2) / columns.length) + 0.12,
        y: 1.64,
        w: (W - M * 2) / columns.length - 0.24,
        h: 0.3,
        fontSize: 12,
        bold: true,
        color: colors.ink,
      })
    );
  } else {
    addTwoColumn(slide, spec);
  }
}

function addClosing(slide, spec) {
  slide.background = { color: colors.bg };
  slide.addShape(shape.arc, {
    x: -1.3,
    y: 1.35,
    w: 4.8,
    h: 4.8,
    rotate: 210,
    fill: { color: colors.accent2, transparency: 86 },
    line: { color: colors.accent2, transparency: 45, width: 1.2 },
  });
  addKicker(slide, spec.kicker || "END / NEXT", M, 0.95);
  addText(slide, spec.title || "Thank you", {
    x: M,
    y: 2.05,
    w: 8.9,
    h: 1.2,
    fontFace: TITLE_FONT,
    fontSize: 48,
    bold: true,
  });
  addText(slide, spec.subtitle || spec.contact || "", {
    x: M,
    y: 3.55,
    w: 7.8,
    h: 0.75,
    fontSize: 20,
    color: colors.muted,
  });
  slide.addShape(shape.line, {
    x: M,
    y: 4.75,
    w: 1.5,
    h: 0,
    line: { color: colors.accent, width: 5 },
  });
}

function renderSlide(spec) {
  const slide = pptx.addSlide("LINGSHU");
  slide.background = { color: colors.bg };
  const layout = text(spec.layout || "bullets").toLowerCase();
  switch (layout) {
    case "cover": addCover(slide, spec); break;
    case "agenda": addAgenda(slide, spec); break;
    case "section": addSection(slide, spec); break;
    case "bignumber": addBigNumber(slide, spec); break;
    case "image-left": addImageSplit(slide, spec, true); break;
    case "image-right": addImageSplit(slide, spec, false); break;
    case "image-full": addImageFull(slide, spec); break;
    case "twocol": addTwoColumn(slide, spec); break;
    case "timeline": addTimeline(slide, spec); break;
    case "quote": addQuote(slide, spec); break;
    case "chart": addChart(slide, spec); break;
    case "compare": addCompare(slide, spec); break;
    case "closing": addClosing(slide, spec); break;
    case "bullets":
    default: addBullets(slide, spec); break;
  }
  if (spec.notes) slide.addNotes(text(spec.notes));
  return slide;
}

if (!slides.length) {
  console.error("slides must contain at least one slide");
  process.exit(65);
}

slides.forEach(renderSlide);
fs.mkdirSync(path.dirname(outputPath), { recursive: true });

// PptxGenJS uses dynamic imports for Node file/media I/O. Single-file runtimes
// such as pkg execute application code in a VM snapshot where those imports do
// not have a callback. All media above is already embedded, so ask PptxGenJS
// for an in-memory package and let this adapter perform the final static write.
Object.defineProperty(process.release, "name", { value: "browser", configurable: true });
pptx
  .write({ outputType: "nodebuffer", compression: true })
  .then((buffer) => {
    fs.writeFileSync(outputPath, buffer);
    const size = fs.statSync(outputPath).size;
    console.log(`OK engine=pptxgenjs pages=${slides.length} bytes=${size}`);
  })
  .catch((error) => {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  });
