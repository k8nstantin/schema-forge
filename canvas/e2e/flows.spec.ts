// Every flow of the canvas, in the browser, on every engine of the test registry (docs/api.md). Each flow is written
// here before the screen that does it; a flow still marked `fixme` is one the canvas does not do yet.

import { expect, test } from '@playwright/test'

import { fixtures } from './engines'

test('the canvas is served by the test server', async ({ page }) => {
  await page.goto('/')
  await expect(page).toHaveTitle('Schema Forge')
})

test.fixme('the server lists every engine the fixtures drive, and no other', async ({ request }) => {
  const engines = await (await request.get('/api/engines')).json()
  expect(engines.map((e: { id: string }) => e.id)).toEqual(fixtures().map((f) => f.id))
})

for (const fx of fixtures()) {
  test.describe(`engine ${fx.id}`, () => {
    test.fixme('Home lists the engine, what it reads, and the way in from a file and from a live database', async () => {})
    test.fixme('a file is read in: chosen in the browser, named, read, and its report shown, adding up', async () => {})
    test.fixme('the schema opens on its tables: each object by namespace and kind, in the engine’s words', async () => {})
    test.fixme('a table shows its columns, keys and indexes, its links, and its definition as the engine writes it', async () => {})
    test.fixme('every other kind of object shows what it holds and its definition', async () => {})
    test.fixme('Categories and Map draw the families and their links', async () => {})
    test.fixme('the whole schema downloads as the engine’s SQL', async () => {})
    test.fixme('a reference is pointed at and copied for the agent', async () => {})
    test.fixme('the schema is removed from Home', async () => {})
    if (fx.live) {
      test.fixme('a connection is made from the engine’s fields, listed by its summary, never its secret', async () => {})
      test.fixme('a connection is tested: every step shown, a wrong secret failing where it fails', async () => {})
      test.fixme('a live database is read into a schema, only what is named, and opened', async () => {})
    }
  })
}
