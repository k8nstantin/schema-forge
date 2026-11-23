// What each engine's browser tests read: the same fixtures as the server's tests (crates/serve/tests/fixtures), so
// every engine of the test registry is driven through every flow, and none is named in the test code.

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export interface Fixture {
  id: string
  /// A sample file, absolute.
  file: string
  /// A connection whose live database needs no service, its path values absolute.
  live?: { values: Record<string, string>; secret: string; which: string[] }
}

const root = fileURLToPath(new URL('../../', import.meta.url))

export function fixtures(): Fixture[] {
  const all = JSON.parse(readFileSync(join(root, 'crates/serve/tests/fixtures/engines.json'), 'utf8'))
  return Object.entries(all)
    .filter(([id]) => !id.startsWith('_'))
    .map(([id, f]) => {
      const fx = f as { file: string; live?: Fixture['live'] }
      return { id, file: join(root, fx.file), live: fx.live }
    })
}

export const repo = root
