// The canvas: built in the next step against docs/api.md, its types generated from the server's (src/api/types.ts).
// Until then it says so, and the browser tests that describe it wait (e2e/).

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <main>Schema Forge</main>
  </StrictMode>,
)
