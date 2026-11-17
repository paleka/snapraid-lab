// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robert Paleka
// Takes the screenshots of docs/screenshots from a running lab, with Playwright and Chrome:
//     node docs/tools/shots.mjs docs/tools/shots-ready.json
// The files are written in the current folder. PLAYWRIGHT and CHROME say where the two are.
const { chromium } = await import(process.env.PLAYWRIGHT || 'playwright');
import fs from 'fs';
const shots = JSON.parse(fs.readFileSync(process.argv[2])).shots;
const b = await chromium.launch({ executablePath: process.env.CHROME || undefined, args: ['--no-sandbox', '--no-proxy-server'] });
for (const s of shots) {
    const ctx = await b.newContext({ viewport: { width: s.w || 1360, height: s.h || 850 }, deviceScaleFactor: 1 });
    const p = await ctx.newPage();
    await p.goto('http://127.0.0.1:7627/');
    await p.evaluate(a => localStorage.setItem('array', a), s.array || 'default');
    await p.goto('http://127.0.0.1:7627/' + s.hash);
    await p.reload();
    await p.waitForTimeout(2200);
    for (const st of s.steps || []) {
        try {
            if (st.click) await p.locator(st.click).first().click({ timeout: 5000 });
            else if (st.text) await p.getByText(st.text, { exact: !!st.exact }).first().click({ timeout: 5000 });
            else if (st.fill) await p.locator(st.fill).first().fill(st.value);
            else if (st.select) await p.locator(st.select).first().selectOption(st.value);
            else if (st.check) await p.locator(st.check).first().check({ timeout: 5000 });
            else if (st.scroll) await p.locator(st.scroll).first().scrollIntoViewIfNeeded();
            else if (st.eval) await p.evaluate(st.eval);
            await p.waitForTimeout(st.wait || 900);
        } catch (e) { console.log(`${s.name}: step ${JSON.stringify(st)} failed: ${String(e).split('\n')[0]}`); }
    }
    await p.screenshot({ path: `${s.name}.png` });
    console.log('shot', s.name);
    await ctx.close();
}
await b.close();
