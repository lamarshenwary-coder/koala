// Headless render of each pet state -> web/shots/<state>.png (local playwright + PW_CHROMIUM env)
const { chromium } = require('playwright')
const path = require('path')
;(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PW_CHROMIUM || '/opt/pw-browsers/chromium',
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--no-sandbox'],
  })
  const page = await browser.newPage({ viewport: { width: 320, height: 320 }, deviceScaleFactor: 2 })
  page.on('pageerror', e => console.log('PAGE ERROR', e.message))
  page.on('console', m => { if (m.type() === 'error') console.log('CONSOLE', m.text()) })
  const file = 'file://' + path.resolve(__dirname, '../dist/index.html')
  const fs = require('fs')
  fs.mkdirSync(path.resolve(__dirname, '../shots'), { recursive: true })
  for (const s of ['idle', 'listening', 'thinking', 'done', 'noting', 'confused', 'sleeping']) {
    await page.goto(`${file}?bg=1&state=${s}`)
    await page.waitForTimeout(s === 'done' ? 350 : 900)
    await page.screenshot({ path: path.resolve(__dirname, `../shots/${s}.png`) })
    console.log('shot', s)
  }
  await browser.close()
})().catch(e => { console.error(e); process.exit(1) })
