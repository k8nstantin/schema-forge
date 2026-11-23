import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { defineConfig, devices } from '@playwright/test'

// The browser tests run against the test server (crates/serve/src/bin/test_server.rs): the real server, with the
// test registry, over a workspace made for this run, serving the canvas built in dist/ (tools/check.sh builds it
// first).
const port = 7411
const workspace = mkdtempSync(join(tmpdir(), 'schema-forge-e2e-'))

export default defineConfig({
  testDir: 'e2e',
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  reporter: [['list']],
  use: { baseURL: `http://127.0.0.1:${port}`, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `cargo run --quiet -p schema-forge-serve --features test-engines --bin schema-forge-test-server -- ${port} ${workspace}`,
    cwd: '..',
    url: `http://127.0.0.1:${port}/`,
    timeout: 300_000,
    reuseExistingServer: false,
  },
})
