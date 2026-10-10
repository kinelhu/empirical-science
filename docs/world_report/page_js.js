(function () {
  const NS = "http://www.w3.org/2000/svg";
  const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  function el(tag, attrs, parent, text) {
    const n = document.createElementNS(NS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    if (text !== undefined) n.textContent = text;
    if (parent) parent.appendChild(n);
    return n;
  }
  const font = "IBM Plex Mono, ui-monospace, monospace";

  // Responsiveness: horizontal bars, sorted, a reference line at 1.0.
  function drawResp() {
    const svg = document.getElementById("resp");
    const rows = DATA.targets.slice().sort((a, b) => b.resp - a.resp);
    const W = 900, left = 190, right = 60, rowH = 17, top = 18;
    const H = top + rows.length * rowH + 26;
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    const max = 1.4, x = (v) => left + (v / max) * (W - left - right);
    for (const t of [0, 0.5, 1.0]) {
      el("line", {x1: x(t), x2: x(t), y1: top - 6, y2: H - 22, stroke: t === 1 ? css("--ink") : css("--rule"),
        "stroke-width": t === 1 ? 1.2 : 1, "stroke-dasharray": t === 1 ? "4 3" : ""}, svg);
      el("text", {x: x(t), y: H - 6, "text-anchor": "middle", fill: css("--muted"), "font-size": 11, "font-family": font}, svg, t.toFixed(1));
    }
    rows.forEach((r, i) => {
      const y = top + i * rowH;
      el("text", {x: left - 8, y: y + 11, "text-anchor": "end", fill: css("--ink"), "font-size": 12, "font-family": "IBM Plex Sans, sans-serif"}, svg, r.name);
      el("rect", {x: left, y: y + 2, width: Math.max(1, x(r.resp) - left), height: rowH - 6,
        fill: r.resp >= 1 ? css("--accent") : css("--muted"), rx: 1}, svg);
      el("text", {x: x(r.resp) + 6, y: y + 11, fill: css("--muted"), "font-size": 11, "font-family": font}, svg, r.resp.toFixed(2));
    });
  }

  // Family chemistry: a symmetric heat table, diverging around zero.
  function drawChem() {
    const svg = document.getElementById("chem");
    const F = DATA.fams, n = F.length, cell = 46, left = 96, top = 96;
    const W = left + n * cell + 10, H = top + n * cell + 10;
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    const label = (f) => f.charAt(0).toUpperCase() + f.slice(1);
    const gain = css("--gain"), loss = css("--loss"), sheet = css("--sheet");
    F.forEach((f, i) => {
      el("text", {x: left - 8, y: top + i * cell + cell / 2 + 4, "text-anchor": "end", fill: css("--ink"), "font-size": 12,
        "font-family": "IBM Plex Sans, sans-serif"}, svg, label(f));
      const tx = left + i * cell + cell / 2, ty = top - 8;
      el("text", {x: tx, y: ty, transform: `rotate(-50 ${tx} ${ty})`, fill: css("--ink"), "font-size": 12,
        "font-family": "IBM Plex Sans, sans-serif"}, svg, label(f));
    });
    for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
      const v = DATA.chem[i][j];
      const a = Math.min(1, Math.abs(v) / 0.25);
      const g = el("g", {}, svg);
      el("rect", {x: left + j * cell + 1, y: top + i * cell + 1, width: cell - 2, height: cell - 2,
        fill: i === j ? css("--soft") : (v >= 0 ? gain : loss), "fill-opacity": i === j ? 1 : (0.12 + 0.78 * a)}, g);
      if (i !== j) el("text", {x: left + j * cell + cell / 2, y: top + i * cell + cell / 2 + 4, "text-anchor": "middle",
        fill: a > 0.65 ? sheet : css("--ink"), "font-size": 11, "font-family": font}, g, (v >= 0 ? "+" : "") + v.toFixed(2));
    }
  }

  // Chains: three bars per final product.
  function drawChains() {
    const svg = document.getElementById("chains");
    const rows = DATA.chains.slice().sort((a, b) => b.late - a.late);
    const W = 900, left = 190, right = 60, group = 44, top = 10;
    const H = top + rows.length * group + 26;
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    const max = Math.ceil(Math.max(...rows.map((r) => r.late)) / 10) * 10;
    const x = (v) => left + (Math.max(0, v) / max) * (W - left - right);
    for (let t = 0; t <= max; t += 10) {
      el("line", {x1: x(t), x2: x(t), y1: top, y2: H - 22, stroke: css("--rule")}, svg);
      el("text", {x: x(t), y: H - 6, "text-anchor": "middle", fill: css("--muted"), "font-size": 11, "font-family": font}, svg, t + "%");
    }
    const series = [["single", "--muted"], ["chain", "--accent"], ["late", "--gain"]];
    rows.forEach((r, i) => {
      const y = top + i * group;
      el("text", {x: left - 8, y: y + 21, "text-anchor": "end", fill: css("--ink"), "font-size": 12,
        "font-family": "IBM Plex Sans, sans-serif"}, svg, r.name);
      series.forEach(([k, c], s) => {
        const yy = y + 4 + s * 11;
        el("rect", {x: left, y: yy, width: Math.max(1, x(r[k]) - left), height: 9, fill: css(c), rx: 1}, svg);
        el("text", {x: x(r[k]) + 5, y: yy + 8, fill: css("--muted"), "font-size": 10, "font-family": font}, svg, r[k].toFixed(1) + "%");
      });
    });
  }

  function drawAll() {
    for (const id of ["resp", "chem", "chains"]) document.getElementById(id).replaceChildren();
    drawResp(); drawChem(); drawChains();
  }
  drawAll();
  // Redraw with the theme's colours when it changes.
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  if (mq.addEventListener) mq.addEventListener("change", drawAll);
  new MutationObserver(drawAll).observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]});
})();
