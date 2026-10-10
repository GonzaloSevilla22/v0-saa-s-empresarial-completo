import { chromium, loginAll } from './humo-lib.mjs'
const browser = await chromium.launch()
await loginAll(browser)
await browser.close()
